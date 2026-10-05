import Foundation

/// Einstellungen der App (UserDefaults; die App ist nicht sandboxed).
enum AppSettings {
    static let defaultProjectPath = "\(NSHomeDirectory())/Documents/Pace Lab"

    enum Key {
        static let projectPath = "projectPath"
        static let athleteName = "athleteName"
    }

    static var projectPath: String {
        UserDefaults.standard.string(forKey: Key.projectPath) ?? defaultProjectPath
    }

    /// Wie der Coach dich anspricht (leer = neutral).
    static var athleteName: String {
        (UserDefaults.standard.string(forKey: Key.athleteName) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Eigene Dateien der App (Gespräche, Modelllisten, Garmin-Server) in Application Support.
    static let supportDirectory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Pace Lab", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Der Trainings-Projektordner (plan.json, analysis.json, completed.json, README.md, garmin-mcp/ …).
struct ProjectFolder: Sendable {
    let url: URL

    static var current: ProjectFolder { ProjectFolder(url: URL(filePath: AppSettings.projectPath, directoryHint: .isDirectory)) }

    func file(_ name: String) -> URL { url.appending(path: name) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }

    /// Änderungsstempel der Datendateien — ändert sich, sobald jemand (Claude, App, Hand) schreibt.
    func signature() -> [String] {
        (TrainingFiles.all + [PlanFiles.draft]).map { name in
            let values = try? file(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(name):\(stamp):\(values?.fileSize ?? -1)"
        }
    }

    func readFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in TrainingFiles.all where exists(name) {
            files[name] = try Data(contentsOf: file(name))
        }
        guard files[TrainingFiles.plan] != nil else { throw StoreError.missingFile(TrainingFiles.plan) }
        guard files[TrainingFiles.analysis] != nil else { throw StoreError.missingFile(TrainingFiles.analysis) }
        return files
    }

    /// Setzt oder entfernt ein Häkchen direkt in completed.json. Bestehende Einträge
    /// behalten Reihenfolge und Format, neue kommen ans Ende.
    func setCompleted(_ done: Bool, sessionID: String, on date: Date = .now) throws {
        let url = file(TrainingFiles.completed)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "{}"
        var entries = try CompletedJSON.parse(raw)
        if done {
            let value = CompletedJSON.Value.string(DateUtil.germanDay(date))
            if let i = entries.firstIndex(where: { $0.key == sessionID }) {
                entries[i].value = value
            } else {
                entries.append(.init(key: sessionID, value: value))
            }
        } else {
            entries.removeAll { $0.key == sessionID }
        }
        try CompletedJSON.render(entries).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Flaches JSON-Objekt mit stabiler Schlüssel-Reihenfolge (JSONSerialization kennt keine).
enum CompletedJSON {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
    }

    struct Entry {
        var key: String
        var value: Value
    }

    static func parse(_ text: String) throws -> [Entry] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let dict = object as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }

        // Schlüssel in Datei-Reihenfolge: in einem flachen Objekt folgt nur auf Schlüssel ein Doppelpunkt.
        let pattern = /"((?:[^"\\]|\\.)*)"\s*:/
        var ordered: [String] = []
        for match in text.matches(of: pattern) {
            let quoted = "\"\(match.1)\""
            if let key = try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed) as? String,
               dict[key] != nil, !ordered.contains(key) {
                ordered.append(key)
            }
        }
        for key in dict.keys.sorted() where !ordered.contains(key) { ordered.append(key) }

        return ordered.map { key in
            let raw = dict[key]!
            if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(), let flag = raw as? Bool {
                return Entry(key: key, value: .bool(flag))
            }
            return Entry(key: key, value: .string(raw as? String ?? "\(raw)"))
        }
    }

    static func render(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "{}\n" }
        let lines = entries.map { entry -> String in
            let value = switch entry.value {
            case .string(let s): quote(s)
            case .bool(let b): b ? "true" : "false"
            }
            return "  \(quote(entry.key)): \(value)"
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    private static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
