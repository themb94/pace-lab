import Foundation

/// Eine hinterlegte CLI, die als Coach arbeiten kann.
struct CoachEngine: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Claude Code — Agent mit Dateien, Strava, Garmin, Gedächtnis.
        case claudeCode
        /// OpenAI Codex — Agent mit Dateien; Läufe direkt über Garmin (Strava geht dort nicht).
        case codex
        /// Beliebige CLI: Frage rein, Antwort als Text raus (z. B. lokale Modelle über `lms`).
        case textCLI

        var id: String { rawValue }

        var label: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .textCLI: "Eigene CLI (nur Text)"
            }
        }

        var symbol: String {
            switch self {
            case .claudeCode: "sparkles"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .textCLI: "terminal"
            }
        }

        /// Agenten lesen/schreiben Dateien und nutzen Strava/Garmin; reine Text-CLIs antworten nur.
        var isAgent: Bool { self != .textCLI }

        var defaultCommand: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            case .textCLI: ""
            }
        }

        var capabilities: String {
            switch self {
            case .claudeCode: "Agent: liest und ändert Dateien, Strava, Garmin (Upload nur mit Freigabe), Gedächtnis aus dem Chat."
            case .codex: "Agent: liest und ändert Dateien, holt Läufe direkt über Garmin (kein Strava), Workouts anlegen nur mit Freigabe. Kein Claude-Gedächtnis — nur README."
            case .textCLI: "Nur Text: antwortet anhand des mitgeschickten Trainingsstands, kann aber keine Läufe abrufen oder Dateien ändern."
            }
        }
    }

    enum ContextLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        case compact, full, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .compact: "Kompakt (Plan, Woche, letzte Läufe)"
            case .full: "Ausführlich (zusätzlich README)"
            case .none: "Keiner"
            }
        }
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// Pfad oder Befehlsname; leer = Standardbefehl des Typs suchen.
    var executable: String
    /// Leer = Standard der CLI.
    var model: String
    /// Denktiefe (Claude: --effort, Codex: model_reasoning_effort); leer = Standard.
    var effort: String
    /// Text-CLI: Argumente mit {model}, {prompt}, {system}. Agenten: zusätzliche Argumente.
    var arguments: String
    /// Text-CLI: Befehl, der vor jeder Anfrage läuft (z. B. Modell laden). Platzhalter {model}.
    var prepareCommand: String
    /// Text-CLI: wie viel Trainingsstand die App mitschickt.
    var context: ContextLevel

    init(id: UUID = UUID(), name: String, kind: Kind, executable: String = "", model: String = "",
         effort: String = "", arguments: String = "", prepareCommand: String = "", context: ContextLevel = .compact) {
        self.id = id
        self.name = name
        self.kind = kind
        self.executable = executable
        self.model = model
        self.effort = effort
        self.arguments = arguments
        self.prepareCommand = prepareCommand
        self.context = context
    }

    /// Tolerant gegenüber fehlenden Feldern (spätere App-Versionen).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Coach"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .claudeCode
        executable = try c.decodeIfPresent(String.self, forKey: .executable) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        prepareCommand = try c.decodeIfPresent(String.self, forKey: .prepareCommand) ?? ""
        context = try c.decodeIfPresent(ContextLevel.self, forKey: .context) ?? .compact
    }

    /// Kurzbeschreibung für Menüs: "Codex · gpt-5.6-terra"
    var summary: String {
        model.isEmpty ? name : "\(name) · \(model)"
    }

    /// Der tatsächlich aufzurufende Befehl (leer → Standard des Typs).
    var command: String {
        executable.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultCommand : executable
    }
}

// MARK: - Vorlagen

extension CoachEngine {
    static func claudePreset() -> CoachEngine {
        CoachEngine(name: "Claude Code", kind: .claudeCode)
    }

    static func codexPreset() -> CoachEngine {
        CoachEngine(name: "Codex", kind: .codex, model: ModelCatalog.codexModels().first ?? "")
    }

    /// Lokales Modell über die LM-Studio-CLI (auch in Bionic enthalten). Lädt das Modell nur,
    /// wenn es nicht schon geladen ist, und gibt es nach 15 Minuten ohne Nutzung wieder frei.
    static func lmStudioPreset(model: String = "") -> CoachEngine {
        CoachEngine(
            name: "Lokal (LM Studio / Bionic)", kind: .textCLI, executable: "lms", model: model,
            arguments: "chat {model} -p {prompt} -s {system}",
            prepareCommand: "/bin/sh -c 'lms ps --json | grep -q \"{model}\" || lms load \"{model}\" -y --ttl 900 -c 8192'",
            context: .compact)
    }

    static func customPreset() -> CoachEngine {
        CoachEngine(name: "Eigene CLI", kind: .textCLI, executable: "", arguments: "{prompt}", context: .compact)
    }
}

// MARK: - Speicher

/// Hinterlegte Engines und die gewählte, in den UserDefaults der App.
enum EngineStore {
    private static let enginesKey = "coachEngines"
    private static let selectedKey = "coachEngineID"

    static func load() -> [CoachEngine] {
        if let data = UserDefaults.standard.data(forKey: enginesKey),
           let engines = try? JSONDecoder().decode([CoachEngine].self, from: data), !engines.isEmpty {
            return engines
        }
        // Gleich speichern, damit die IDs stabil bleiben (Gespräche und Auswahl verweisen darauf).
        let engines = defaults()
        save(engines)
        return engines
    }

    static func save(_ engines: [CoachEngine]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(engines), forKey: enginesKey)
    }

    static var selectedID: UUID? {
        get { UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: selectedKey) }
    }

    /// Erststart: Claude Code (mit evtl. schon gesetztem Modell), dazu Codex und LM Studio, falls installiert.
    static func defaults() -> [CoachEngine] {
        var claude = CoachEngine.claudePreset()
        claude.model = UserDefaults.standard.string(forKey: "coachModel") ?? ""
        claude.effort = UserDefaults.standard.string(forKey: "coachEffort") ?? ""
        var engines = [claude]
        if CLIResolver.find("codex") != nil { engines.append(.codexPreset()) }
        if CLIResolver.find("lms") != nil { engines.append(.lmStudioPreset()) }
        return engines
    }
}

// MARK: - Modell-Vorschläge

enum ModelCatalog {
    static let claude = ["opus", "sonnet", "fable"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Modelle, die Codex für das angemeldete Konto anbietet (aus Codex' eigenem Cache).
    static func codexModels() -> [String] {
        let url = URL(filePath: NSHomeDirectory()).appending(path: ".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? 999) < ($1["priority"] as? Int ?? 999) }
            .compactMap { $0["slug"] as? String }
    }

    /// Lokale Sprachmodelle aus LM Studio (weckt den LM-Studio-Dienst — nur auf Knopfdruck).
    static func lmStudioModels() -> [String] {
        guard let lms = CLIResolver.find("lms") else { return [] }
        let output = CLIResolver.runSync(lms, ["ls", "--llm", "--json"])
        guard let start = output.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["modelKey"] as? String }
    }
}

// MARK: - Argumente mit Platzhaltern

enum ArgumentTemplate {
    /// Zerlegt eine Befehlszeile wie eine Shell (Leerzeichen trennen, "…" und '…' halten zusammen).
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false
        for ch in line {
            if escaping {
                current.append(ch)
                escaping = false
            } else if ch == "\\" && quote != "'" {
                escaping = true
                inToken = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inToken = true
            } else if ch.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
            } else {
                current.append(ch)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Ersetzt {model}, {prompt}, {system} in jedem Argument — in einem Durchgang, damit
    /// z. B. ein "{system}" im Fragetext nicht noch einmal ersetzt wird.
    static func fill(_ tokens: [String], with values: [String: String]) -> [String] {
        tokens.map { token in
            token.replacing(/\{(model|prompt|system)\}/) { match in values[String(match.1)] ?? String(match.0) }
        }
    }

    static func uses(_ placeholder: String, in line: String) -> Bool {
        line.contains("{\(placeholder)}")
    }
}
