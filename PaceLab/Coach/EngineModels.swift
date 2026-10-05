import Foundation
import Observation
import SwiftUI

/// Ein Modell, das eine Coach-CLI anbietet.
struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    /// Wert für `--model` bzw. `-m` (Alias oder voller Name); "" = Standard der CLI.
    var value: String
    /// Konkretes Modell hinter einem Alias, z. B. „claude-opus-5“.
    var resolved: String?
    /// Anzeigename, z. B. „Opus“ oder „Opus 4.8“.
    var name: String
    /// Version, z. B. „Opus 5“.
    var version: String
    /// Beschreibung, z. B. „für alltägliche, komplexe Aufgaben · ≈ 2× Verbrauch gegenüber Sonnet“.
    var details: String
    /// Mögliche Denktiefen; leer = nicht einstellbar, nil = unbekannt.
    var efforts: [String]?

    var id: String { value }
}

/// Was eine installierte CLI an Modellen anbietet — live abgefragt, nicht fest eingetragen.
struct EngineModels: Codable, Sendable {
    /// Version der CLI, z. B. „2.1.274“.
    var cliVersion: String
    var executable: String
    /// Von der CLI angeboten (Standard + Aliase, die mit Updates mitwandern).
    var options: [ModelOption]
    /// Dieselben Modelle als feste Version.
    var pinned: [ModelOption]
    /// Ältere Versionen, die die installierte CLI noch kennt.
    var older: [ModelOption]
    /// Z. B. „Opus 5.5 gibt es ab Claude Code 2.1.280 …“
    var notices: [String]
    var fetchedAt: Date
    /// Sprache, in der die Beschreibungen beim Abruf übersetzt wurden — bei einem Sprachwechsel wird neu abgefragt.
    var language: String?

    var all: [ModelOption] { options + pinned + older }

    func option(for value: String) -> ModelOption? {
        all.first { $0.value == value }
    }

    /// Anzeige für ein konkretes Modell („claude-opus-5“ → „Opus 5“).
    func version(forResolved id: String) -> String? {
        all.first { $0.resolved == id || $0.value == id }?.version
    }
}

// MARK: - Abfrage

enum ModelDiscovery {
    // MARK: Claude Code

    /// Fragt Claude Code über die SDK-Schnittstelle (`initialize`), welche Modelle es für das Konto anbietet —
    /// ohne ein Modell aufzurufen. Dazu ältere Versionen, die die installierte CLI kennt, und Hinweise auf
    /// Modelle, die erst eine neuere CLI kann.
    static func claude(executable: URL, folder: URL) async throws -> EngineModels {
        let version = cliVersion(executable)
        let request = #"{"type":"control_request","request_id":"pacelab-models","request":{"subtype":"initialize"}}"# + "\n"
        let process = CLIProcess()
        let raw: [[String: Any]] = try await withTaskCancellationHandler {
            let lines = try process.start(executable, [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--strict-mcp-config", "--no-session-persistence",
            ], in: folder, input: request)
            var models: [[String: Any]]?
            for await line in lines where line.first == "{" && models == nil {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "control_response",
                      let response = object["response"] as? [String: Any] else { continue }
                if response["subtype"] as? String == "error" {
                    throw SyncFailure(message: "Claude Code: \(response["error"] as? String ?? String(localized: "model list not available"))")
                }
                models = (response["response"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
                process.cancel()
            }
            _ = await process.waitForExit()
            guard let models else { throw SyncFailure(message: String(localized: "Claude Code didn’t return a model list.")) }
            return models
        } onCancel: {
            process.cancel()
        }

        var options: [ModelOption] = []
        for entry in raw {
            guard let value = entry["value"] as? String else { continue }
            let resolved = entry["resolvedModel"] as? String
            let description = entry["description"] as? String ?? ""
            let parts = description.components(separatedBy: " · ")
            let versionName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? resolved.map(ModelName.pretty) ?? value
            var details = parts.dropFirst().map(ModelName.localizedDescription)
            if value.hasSuffix("[1m]") { details.insert(String(localized: "1M context"), at: 0) }
            let efforts = entry["supportsEffort"] as? Bool == true ? entry["supportedEffortLevels"] as? [String] ?? [] : []
            if value == "default" {
                options.insert(ModelOption(value: "", resolved: resolved, name: String(localized: "Default"), version: versionName,
                                           details: ([String(localized: "recommended by Claude Code")] + details).joined(separator: " · "),
                                           efforts: efforts), at: 0)
            } else {
                options.append(ModelOption(value: value, resolved: resolved, name: entry["displayName"] as? String ?? versionName,
                                           version: versionName, details: details.joined(separator: " · "), efforts: efforts))
            }
        }

        // Dieselben Modelle als feste Version („bleibt Opus 5, auch wenn opus später auf 5.5 zeigt“).
        var pinned: [ModelOption] = []
        for option in options where !option.value.isEmpty {
            guard let resolved = option.resolved, resolved != option.value,
                  !pinned.contains(where: { $0.value == resolved }),
                  !options.contains(where: { $0.value == resolved }) else { continue }
            pinned.append(ModelOption(value: resolved, resolved: resolved, name: option.version, version: option.version,
                                      details: String(localized: "fixed version — stays after updates"), efforts: option.efforts))
        }

        let official = options.compactMap { $0.resolved.flatMap(ClaudeModelID.init) }
        let older = olderVersions(knownIn: executable, official: official)
        return EngineModels(cliVersion: version, executable: executable.path, options: options, pinned: pinned,
                            older: older, notices: updateNotices(installed: version), fetchedAt: .now)
    }

    /// Ältere Versionen aus der installierten CLI (sie bringt eine Tabelle aller Modelle mit, die sie kennt):
    /// je Modellfamilie die bis zu drei neuesten unterhalb des angebotenen Modells.
    static func olderVersions(knownIn executable: URL, official: [ClaudeModelID]) -> [ModelOption] {
        let binary = executable.resolvingSymlinksInPath()
        let result = ProcessRunner.run(URL(filePath: "/usr/bin/grep"),
                                       ["-aoE", "claude-(opus|sonnet|fable|haiku)-[0-9]+(-[0-9]+)?(-[0-9]{8})?", binary.path])
        var counts: [ClaudeModelID: (id: String, count: Int, rank: Int)] = [:]
        for line in result.output.split(separator: "\n") {
            guard let parsed = ClaudeModelID(String(line)) else { continue }
            let key = parsed.version
            // Bevorzugt: ohne Datum und mit Nebenversion („claude-opus-4-0“ statt „claude-opus-4-20250514“).
            let rank = (parsed.dated ? 0 : 2) + (parsed.hasMinor ? 1 : 0)
            let current = counts[key]
            counts[key] = (rank > (current?.rank ?? -1) ? String(line) : current!.id, (current?.count ?? 0) + 1,
                           max(rank, current?.rank ?? -1))
        }
        var older: [ModelOption] = []
        for family in ClaudeModelID.families {
            guard let newest = official.filter({ $0.family == family }).max() else { continue }
            let candidates = counts
                .filter { key, entry in
                    key.family == family && key < newest && key.major >= newest.major - 1 && entry.count >= 5
                        && !official.contains(key)
                }
                .sorted { $0.key > $1.key }
                .prefix(3)
            for (key, entry) in candidates {
                older.append(ModelOption(value: entry.id, resolved: entry.id, name: key.displayName, version: key.displayName,
                                         details: String(localized: "older version — no longer offered by Claude Code"), efforts: nil))
            }
        }
        return older
    }

    /// Modelle, die Claude Code kennt, die aber erst eine neuere Version der CLI kann
    /// (aus Claude Codes eigenem Cache in ~/.claude.json).
    static func updateNotices(installed: String) -> [String] {
        let url = URL(filePath: NSHomeDirectory()).appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extra = root["additionalModelOptionsCache"] as? [[String: Any]] else { return [] }
        return extra.compactMap { entry in
            guard entry["disabled"] as? Bool == true, let label = entry["label"] as? String else { return nil }
            let name = label.replacingOccurrences(of: " (disabled)", with: "")
            let description = entry["description"] as? String ?? ""
            if let match = description.firstMatch(of: /(\d+\.\d+\.\d+)\+?/) {
                let required = String(match.1)
                guard compareVersions(installed, required) == .orderedAscending else { return nil }
                return String(localized: "\(name) is available from Claude Code \(required) (installed: \(installed)). After an update it shows up here automatically.")
            }
            return "\(name): \(description)"
        }
    }

    static func cliVersion(_ executable: URL) -> String {
        let output = ProcessRunner.run(executable, ["--version"]).output
        return output.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }.map(String.init)
            ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Codex

    /// Codex führt die Modelle deines Kontos selbst in ~/.codex/models_cache.json.
    static func codex(executable: URL?) -> EngineModels {
        let version = executable.map(cliVersion) ?? ""
        let home = URL(filePath: NSHomeDirectory()).appending(path: ".codex")
        var options: [ModelOption] = []
        if let data = try? Data(contentsOf: home.appending(path: "models_cache.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for model in models.sorted(by: { ($0["priority"] as? Int ?? 999) < ($1["priority"] as? Int ?? 999) })
            where model["visibility"] as? String == "list" {
                guard let slug = model["slug"] as? String else { continue }
                let efforts = (model["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String }
                let name = model["display_name"] as? String ?? slug
                options.append(ModelOption(value: slug, resolved: slug, name: name, version: name,
                                           details: ModelName.localizedDescription(model["description"] as? String ?? ""), efforts: efforts))
            }
        }
        // Standard laut config.toml — steht er nicht in der Liste, lehnt das Konto ihn ab.
        var notices: [String] = []
        let config = (try? String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)) ?? ""
        let configured = config.split(separator: "\n").lazy
            .compactMap { $0.firstMatch(of: /^\s*model\s*=\s*"([^"]+)"/).map { String($0.1) } }.first
        var standard = ModelOption(value: "", resolved: configured, name: String(localized: "Default"),
                                   version: configured ?? String(localized: "CLI default"), details: String(localized: "from ~/.codex/config.toml"), efforts: nil)
        if let configured, !options.isEmpty, !options.contains(where: { $0.value == configured }) {
            standard.details = String(localized: "from ~/.codex/config.toml — not available for your account")
            notices.append(String(localized: "The default from ~/.codex/config.toml (\(configured)) is not offered for your account — better pick a model from the list here."))
        }
        options.insert(standard, at: 0)
        return EngineModels(cliVersion: version, executable: executable?.path ?? "", options: options, pinned: [],
                            older: [], notices: notices, fetchedAt: .now)
    }
}

/// „claude-opus-4-8“ → Familie opus, Version 4.8.
struct ClaudeModelID: Hashable, Comparable, Sendable {
    static let families = ["opus", "sonnet", "fable", "haiku"]

    let family: String
    let major: Int
    let minor: Int
    var hasMinor = false
    var dated = false

    init?(_ id: String) {
        guard let match = id.wholeMatch(of: /claude-(opus|sonnet|fable|haiku)-(\d+)(?:-(\d))?(?:-(\d{8}))?(?:\[1m\])?/),
              let major = Int(match.2) else { return nil }
        family = String(match.1)
        self.major = major
        minor = match.3.flatMap { Int($0) } ?? 0
        hasMinor = match.3 != nil
        dated = match.4 != nil
    }

    private init(family: String, major: Int, minor: Int) {
        self.family = family
        self.major = major
        self.minor = minor
    }

    /// Nur Familie und Version — zum Gruppieren und Vergleichen.
    var version: ClaudeModelID { ClaudeModelID(family: family, major: major, minor: minor) }

    /// „Opus 4.8“, „Opus 5“
    var displayName: String {
        family.prefix(1).uppercased() + family.dropFirst() + " \(major)" + (minor > 0 ? ".\(minor)" : "")
    }

    static func == (a: ClaudeModelID, b: ClaudeModelID) -> Bool {
        a.family == b.family && a.major == b.major && a.minor == b.minor
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(major)
        hasher.combine(minor)
    }

    static func < (a: ClaudeModelID, b: ClaudeModelID) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }
}

// MARK: - Anzeige

enum ModelName {
    /// „claude-opus-5-5“ → „Opus 5.5“, „claude-haiku-4-5-20251001“ → „Haiku 4.5“; andere Namen bleiben.
    static func pretty(_ id: String) -> String {
        guard let parsed = ClaudeModelID(id) else { return id }
        return parsed.displayName + (id.hasSuffix("[1m]") ? " (1M)" : "")
    }

    static func effortLabel(_ effort: String) -> String {
        ["minimal": "minimal", "low": String(localized: "low"), "medium": String(localized: "medium"), "high": String(localized: "high"), "xhigh": String(localized: "very high"), "max": String(localized: "maximum"),
         "ultra": "ultra"][effort]
            ?? effort
    }

    /// Die bekannten englischen Beschreibungen der CLIs in der Sprache der App (Deutsch: übersetzt, sonst unverändert).
    static func localizedDescription(_ text: String) -> String {
        let known = [
            "Efficient for routine tasks": String(localized: "efficient for routine tasks"),
            "Best for everyday, complex tasks": String(localized: "for everyday, complex tasks"),
            "Most capable for your hardest and longest-running tasks": String(localized: "most capable, for the hardest and longest-running tasks"),
            "Requires usage credits": String(localized: "needs usage credits"),
            "Fastest for quick answers": String(localized: "fastest, for quick answers"),
            "Older balanced model for straightforward work.": String(localized: "older, balanced model for simple tasks"),
            "Older fast and efficient model.": String(localized: "older, fast and economical model"),
            "Legacy coding model.": String(localized: "legacy coding model"),
        ]
        if let german = known[text] { return german }
        if let match = text.wholeMatch(of: /~(\d+(?:\.\d+)?)× usage vs (\w+)/) {
            return String(localized: "≈ \(match.1)× usage compared to \(match.2)")
        }
        return text
    }
}

// MARK: - Speicher

/// Die abgefragten Modelllisten aller hinterlegten CLIs. Sie werden gespeichert, damit die App sie sofort zeigen
/// kann, und neu abgefragt, wenn sich die Version der CLI ändert (z. B. nach einem Homebrew-Update).
@MainActor
@Observable
final class ModelStore {
    private(set) var byEngine: [String: EngineModels] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var lastCheck: [String: Date] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let stored = try? JSONDecoder().decode([String: EngineModels].self, from: data) {
            byEngine = stored.filter { $0.value.language == AppLanguage.code }
        }
    }

    private static var storeURL: URL {
        AppSettings.supportDirectory.appending(path: "models.json")
    }

    private static func key(_ engine: CoachEngine) -> String {
        "\(engine.kind.rawValue)|\(engine.command)"
    }

    func models(for engine: CoachEngine) -> EngineModels? {
        byEngine[Self.key(engine)]
    }

    func isLoading(_ engine: CoachEngine) -> Bool { loading.contains(Self.key(engine)) }

    func error(for engine: CoachEngine) -> String? { errors[Self.key(engine)] }

    /// Eingestelltes Modell als Version, z. B. „Opus 5“ (bzw. „Sonnet 5 (Standard)“).
    func label(for engine: CoachEngine) -> String {
        let value = engine.model
        if let option = models(for: engine)?.option(for: value) {
            return value.isEmpty ? String(localized: "\(option.version) (default)") : option.version
        }
        return value.isEmpty ? String(localized: "Default") : ModelName.pretty(value)
    }

    /// „Claude Code · Opus 5“
    func summary(for engine: CoachEngine) -> String {
        "\(engine.name) · \(label(for: engine))"
    }

    /// Anzeige für ein Modell, das tatsächlich gelaufen ist (aus dem Start-Ereignis der CLI).
    func version(forResolved id: String) -> String {
        for models in byEngine.values {
            if let version = models.version(forResolved: id) { return version }
        }
        return ModelName.pretty(id)
    }

    /// Fragt neu ab, wenn die CLI-Version sich geändert hat, die Liste älter als einen Tag ist oder `force`.
    func refresh(_ engine: CoachEngine, folder: URL, force: Bool = false) async {
        guard engine.kind != .textCLI else { return }   // lokale Modelle nur auf Knopfdruck (weckt LM Studio)
        let key = Self.key(engine)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        lastCheck[key] = .now

        let command = engine.command
        let kind = engine.kind
        let cached = byEngine[key]
        do {
            let fresh: EngineModels? = try await Task.detached(priority: .utility) {
                guard let executable = CLIResolver.find(command) else { throw CoachError.notFound(command) }
                switch kind {
                case .codex:
                    return ModelDiscovery.codex(executable: executable)
                case .claudeCode:
                    if !force, let cached, cached.executable == executable.path,
                       cached.fetchedAt > .now.addingTimeInterval(-24 * 3600),
                       ModelDiscovery.cliVersion(executable) == cached.cliVersion {
                        return nil   // unverändert
                    }
                    return try await ModelDiscovery.claude(executable: executable, folder: folder)
                case .textCLI:
                    return nil
                }
            }.value
            if var fresh {
                fresh.language = AppLanguage.code
                byEngine[key] = fresh
                save()
            }
            errors[key] = nil
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    /// Günstige Prüfung (höchstens einmal pro Stunde): nur die Version der CLI, neue Liste nur bei Änderung.
    func refreshIfStale(_ engine: CoachEngine, folder: URL) async {
        let key = Self.key(engine)
        if let last = lastCheck[key], last > .now.addingTimeInterval(-3600) { return }
        await refresh(engine, folder: folder)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(byEngine).write(to: Self.storeURL, options: .atomic)
        } catch {
            // Nur ein Zwischenspeicher.
        }
    }
}

// MARK: - Auswahl

/// Modellauswahl für Claude Code und Codex: angebotene Modelle, feste Versionen, ältere Versionen.
struct ModelMenu: View {
    @Binding var value: String
    let models: EngineModels?

    var body: some View {
        Menu {
            if let models {
                Section(models.pinned.isEmpty ? String(localized: "Available") : String(localized: "Always the latest")) {
                    ForEach(models.options) { option in
                        item(option, title: option.value.isEmpty ? String(localized: "Default — \(option.version)") : option.name == option.version
                             ? option.version : "\(option.name) — \(option.version)")
                    }
                }
                if !models.pinned.isEmpty {
                    Section(String(localized: "Fixed version")) {
                        ForEach(models.pinned) { item($0, title: $0.version) }
                    }
                }
                if !models.older.isEmpty {
                    Section(String(localized: "Older versions")) {
                        ForEach(models.older) { item($0, title: $0.version) }
                    }
                }
            } else {
                Button(String(localized: "CLI default")) { value = "" }
                ForEach(ModelCatalog.claude, id: \.self) { name in Button(name) { value = name } }
            }
        } label: {
            Text(title)
        }
        .fixedSize()
    }

    private func item(_ option: ModelOption, title: String) -> some View {
        Button {
            value = option.value
        } label: {
            if option.value == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var title: String {
        guard let models, let option = models.option(for: value) else {
            return value.isEmpty ? String(localized: "CLI default") : String(localized: "\(ModelName.pretty(value)) (custom)")
        }
        if models.options.contains(option) {
            if value.isEmpty { return String(localized: "Default — \(option.version)") }
            return models.pinned.isEmpty ? option.version : String(localized: "\(option.name) — \(option.version) (always the latest)")
        }
        if models.pinned.contains(option) { return String(localized: "\(option.version) (fixed)") }
        return String(localized: "\(option.version) (older version)")
    }
}
