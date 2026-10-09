import Foundation

/// A configured CLI that can work as a coach.
struct CoachEngine: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Claude Code — agent with files, Strava, Garmin, memory.
        case claudeCode
        /// OpenAI Codex — agent with files; runs directly via Garmin (Strava doesn't work there).
        case codex
        /// Any CLI: question in, answer out as text (e.g. local models via `lms`).
        case textCLI

        var id: String { rawValue }

        var label: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .textCLI: String(localized: "Custom CLI (text only)")
            }
        }

        var symbol: String {
            switch self {
            case .claudeCode: "sparkles"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .textCLI: "terminal"
            }
        }

        /// Agents read/write files and use Strava/Garmin; plain text CLIs only answer.
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
            case .claudeCode: String(localized: "Agent: reads and edits files, Strava, Garmin (upload only with approval), memory from the chat.")
            case .codex: String(localized: "Agent: reads and edits files, fetches runs directly through Garmin (no Strava), creates workouts only with approval. No Claude memory — README only.")
            case .textCLI: String(localized: "Text only: answers from the training status sent along, but cannot fetch runs or change files.")
            }
        }
    }

    enum ContextLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        case compact, full, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .compact: String(localized: "Compact (plan, week, latest runs)")
            case .full: String(localized: "Detailed (plus README)")
            case .none: String(localized: "None")
            }
        }
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// Path or command name; empty = look for the type's default command.
    var executable: String
    /// Empty = the CLI's default.
    var model: String
    /// Reasoning effort (Claude: --effort, Codex: model_reasoning_effort); empty = default.
    var effort: String
    /// Text CLI: arguments with {model}, {prompt}, {system}. Agents: additional arguments.
    var arguments: String
    /// Text CLI: command that runs before every request (e.g. load the model). Placeholder {model}.
    var prepareCommand: String
    /// Text CLI: how much of the training state the app sends along.
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

    /// Tolerant of missing fields (later app versions).
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

    /// Short description for menus: "Codex · gpt-5.6-terra"
    var summary: String {
        model.isEmpty ? name : "\(name) · \(model)"
    }

    /// The command that actually gets called (empty → the type's default).
    var command: String {
        executable.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultCommand : executable
    }
}

// MARK: - Templates

extension CoachEngine {
    static func claudePreset() -> CoachEngine {
        CoachEngine(name: "Claude Code", kind: .claudeCode)
    }

    static func codexPreset() -> CoachEngine {
        CoachEngine(name: "Codex", kind: .codex, model: ModelCatalog.codexModels().first ?? "")
    }

    /// Local model via the LM Studio CLI (also included in Bionic). Only loads the model
    /// if it isn't loaded already, and frees it again after 15 minutes without use.
    static func lmStudioPreset(model: String = "") -> CoachEngine {
        CoachEngine(
            name: String(localized: "Local (LM Studio / Bionic)"), kind: .textCLI, executable: "lms", model: model,
            arguments: "chat {model} -p {prompt} -s {system}",
            prepareCommand: "/bin/sh -c 'lms ps --json | grep -q \"{model}\" || lms load \"{model}\" -y --ttl 900 -c 8192'",
            context: .compact)
    }

    static func customPreset() -> CoachEngine {
        CoachEngine(name: String(localized: "Custom CLI"), kind: .textCLI, executable: "", arguments: "{prompt}", context: .compact)
    }
}

// MARK: - Storage

/// Configured engines and the selected one, in the active profile's UserDefaults.
enum EngineStore {
    private static let enginesKey = "coachEngines"
    private static let selectedKey = "coachEngineID"

    static func load() -> [CoachEngine] {
        if let data = AppSettings.defaults.data(forKey: enginesKey),
           let engines = try? JSONDecoder().decode([CoachEngine].self, from: data), !engines.isEmpty {
            return engines
        }
        // Save right away so the IDs stay stable (conversations and selection refer to them).
        let engines = defaults()
        save(engines)
        return engines
    }

    static func save(_ engines: [CoachEngine]) {
        AppSettings.defaults.set(try? JSONEncoder().encode(engines), forKey: enginesKey)
    }

    static var selectedID: UUID? {
        get { AppSettings.defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)) }
        set { AppSettings.defaults.set(newValue?.uuidString, forKey: selectedKey) }
    }

    /// First launch: Claude Code (with a model possibly already set), plus Codex and LM Studio if installed.
    static func defaults() -> [CoachEngine] {
        var claude = CoachEngine.claudePreset()
        claude.model = AppSettings.defaults.string(forKey: "coachModel") ?? ""
        claude.effort = AppSettings.defaults.string(forKey: "coachEffort") ?? ""
        var engines = [claude]
        if CLIResolver.find("codex") != nil { engines.append(.codexPreset()) }
        if CLIResolver.find("lms") != nil { engines.append(.lmStudioPreset()) }
        return engines
    }
}

// MARK: - Model suggestions

enum ModelCatalog {
    static let claude = ["opus", "sonnet", "fable"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Models Codex offers for the signed-in account (from Codex's own cache).
    static func codexModels() -> [String] {
        let url = ActiveProfile.current.codexDirectory.appending(path: "models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? 999) < ($1["priority"] as? Int ?? 999) }
            .compactMap { $0["slug"] as? String }
    }

    /// Local language models from LM Studio (wakes the LM Studio service — only on demand).
    static func lmStudioModels() -> [String] {
        guard let lms = CLIResolver.find("lms") else { return [] }
        let output = CLIResolver.runSync(lms, ["ls", "--llm", "--json"])
        guard let start = output.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["modelKey"] as? String }
    }
}

// MARK: - Arguments with placeholders

enum ArgumentTemplate {
    /// Splits a command line like a shell (spaces separate, "…" and '…' keep things together).
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

    /// Replaces {model}, {prompt}, {system} in every argument — in a single pass, so that
    /// e.g. a "{system}" in the question text isn't replaced a second time.
    static func fill(_ tokens: [String], with values: [String: String]) -> [String] {
        tokens.map { token in
            token.replacing(/\{(model|prompt|system)\}/) { match in values[String(match.1)] ?? String(match.0) }
        }
    }

    static func uses(_ placeholder: String, in line: String) -> Bool {
        line.contains("{\(placeholder)}")
    }
}
