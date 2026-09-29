import Foundation

/// Versionsverwaltung des Trainingsordners mit git. Die App hält jede Änderung als eigenen Stand fest —
/// Coach-Läufe, Häkchen, geladene Läufe, übernommene Pläne —, damit sich alles nachvollziehen und
/// rückgängig machen lässt. Ein Actor, damit nie zwei git-Befehle gleichzeitig laufen.
actor ProjectHistory {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let parents: [String]
        let date: Date
        let subject: String
        let body: String
        let files: [FileStat]

        var shortID: String { String(id.prefix(7)) }
        /// Der erste Stand und Zusammenführungen lassen sich nicht einzeln zurücknehmen.
        var canRevert: Bool { parents.count == 1 }
    }

    struct FileStat: Hashable, Sendable {
        let path: String
        /// nil bei Binärdateien.
        let added: Int?
        let removed: Int?
    }

    enum RevertOutcome: Sendable {
        case reverted(String)
        case nothingToDo
        /// Spätere Änderungen überschneiden sich — nur „Dateien zurücksetzen“ ginge noch.
        case conflict
    }

    enum Failure: LocalizedError {
        case gitMissing
        case command(String)

        var errorDescription: String? {
            switch self {
            case .gitMissing: "git wurde nicht gefunden (Xcode oder die Command Line Tools installieren)."
            case .command(let message): message
            }
        }
    }

    /// Nachricht für Änderungen, die niemand über die App gemacht hat (z. B. im Chat oder von Hand).
    static let externalChanges = "Änderungen außerhalb der App"

    nonisolated let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    nonisolated var isRepository: Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
    }

    nonisolated static var gitURL: URL? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return nil
    }

    // MARK: Einrichten

    /// Legt das Repository an (falls nötig), mit .gitignore, und hält den aktuellen Stand fest.
    func setUp() throws {
        if !isRepository {
            try git(["init", "-q", "-b", "main"])
        }
        let ignore = folder.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Self.defaultIgnore.write(to: ignore, atomically: true, encoding: .utf8)
        }
        try commit("Ausgangsstand")
    }

    static let defaultIgnore = """
    # macOS
    .DS_Store

    # Python (Garmin-Server)
    garmin-mcp/.venv/
    __pycache__/
    *.pyc

    # Xcode
    xcuserdata/
    *.xcuserstate
    build/
    DerivedData/

    # Lokale Freigaben von Claude Code
    .claude/settings.local.json

    """

    // MARK: Stände festhalten

    /// Hält Änderungen als neuen Stand fest — alle oder nur die genannten Pfade.
    /// Gibt den neuen Stand zurück oder nil, wenn sich nichts geändert hat.
    @discardableResult
    func commit(_ message: String, paths: [String]? = nil) throws -> String? {
        guard isRepository else { return nil }
        let changed = try changedPaths(paths)
        guard !changed.isEmpty else { return nil }
        try git(["add", "-A", "--"] + changed)
        try git(["commit", "-q", "--no-verify", "-m", message, "--"] + changed)
        return try head()
    }

    /// Hält Fremdänderungen fest und liefert den aktuellen Stand — der Ausgangspunkt eines Coach-Laufs.
    func checkpoint() throws -> String? {
        guard isRepository else { return nil }
        try commit(Self.externalChanges)
        return try head()
    }

    func head() throws -> String? {
        guard isRepository else { return nil }
        let out = try? git(["rev-parse", "--verify", "-q", "HEAD"])
        return out?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Geänderte Pfade (inkl. neuer und gelöschter Dateien), relativ zum Ordner.
    private func changedPaths(_ paths: [String]?) throws -> [String] {
        let output = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + (paths ?? []))
        var result: [String] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            result.append(String(entry.dropFirst(3)))
            // Bei Umbenennungen folgt der alte Pfad als eigener Eintrag.
            if status.contains("R") || status.contains("C"), let original = entries.popFirst() {
                result.append(original)
            }
        }
        var unique: [String] = []
        for path in result where !unique.contains(path) { unique.append(path) }
        return unique
    }

    // MARK: Lesen

    func log(limit: Int = 300) throws -> [Entry] {
        guard isRepository, try head() != nil else { return [] }
        let output = try git(["log", "-n", "\(limit)", "--format=%x1e%H%x1f%P%x1f%at%x1f%s%x1f%b%x1f", "--numstat"])
        return output.split(separator: "\u{1e}").compactMap { chunk -> Entry? in
            let fields = chunk.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            let files = fields[5].split(separator: "\n").compactMap { line -> FileStat? in
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { return nil }
                return FileStat(path: String(parts[2]), added: Int(parts[0]), removed: Int(parts[1]))
            }
            return Entry(
                id: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                subject: String(fields[3]),
                body: fields[4].trimmingCharacters(in: .whitespacesAndNewlines),
                files: files)
        }
    }

    /// Unterschiede eines Stands zu seinem Vorgänger (unified diff).
    func diff(of commit: String) throws -> String {
        try git(["show", "--format=", "--no-color", "--no-ext-diff", "-U3", commit])
    }

    /// Inhalt einer Datei in einem bestimmten Stand (nil, wenn es sie dort nicht gab).
    func contents(of path: String, at commit: String) -> Data? {
        guard let text = try? git(["show", "\(commit):\(path)"]) else { return nil }
        return Data(text.utf8)
    }

    func changedFiles(from base: String, to target: String) throws -> [String] {
        try git(["diff", "--name-only", "--no-renames", base, target])
            .split(separator: "\n").map(String.init)
    }

    // MARK: Zurücknehmen

    /// Nimmt die Änderungen eines Stands zurück (als neuer Stand). Spätere Änderungen an anderen
    /// Stellen bleiben erhalten; überschneiden sie sich, passiert nichts und es gibt `.conflict`.
    func revert(_ commit: String, message: String) throws -> RevertOutcome {
        try self.commit(Self.externalChanges)
        do {
            try git(["revert", "--no-commit", "--no-edit", commit])
        } catch {
            _ = try? git(["revert", "--abort"])
            _ = try? git(["reset", "-q", "--merge"])
            return .conflict
        }
        guard try !changedPaths(nil).isEmpty else {
            _ = try? git(["revert", "--quit"])
            return .nothingToDo
        }
        try git(["commit", "-q", "--no-verify", "-m", message])
        return .reverted(try head() ?? commit)
    }

    /// Setzt Dateien auf ihren Inhalt in `commit` zurück (dort nicht vorhandene werden gelöscht).
    /// Spätere Änderungen an diesen Dateien gehen dabei verloren.
    @discardableResult
    func restore(_ paths: [String], to commit: String, message: String) throws -> String? {
        try self.commit(Self.externalChanges)
        for path in paths {
            if (try? git(["cat-file", "-e", "\(commit):\(path)"])) != nil {
                try git(["checkout", commit, "--", path])
            } else {
                try? FileManager.default.removeItem(at: folder.appending(path: path))
            }
        }
        return try self.commit(message, paths: paths)
    }

    // MARK: Verlauf löschen

    struct PruneResult: Sendable {
        /// Gelöschte Stände.
        let removed: Int
        /// Behaltene Stände (ohne den neuen Ausgangsstand).
        let kept: Int
        /// Alte → neue Kennung der behaltenen Stände (für Verweise in Coach-Gesprächen).
        let mapping: [String: String]
    }

    /// Löscht alle Stände vor `cutoff` (nil = den ganzen Verlauf). Die Dateien bleiben, wie sie sind: Der jüngste
    /// gelöschte Stand wird zum neuen Ausgangsstand, spätere Stände bleiben mit Nachricht und Datum erhalten.
    /// Danach räumt git die alten Stände endgültig weg — das lässt sich nicht rückgängig machen.
    func deleteHistory(before cutoff: Date?) throws -> PruneResult {
        guard isRepository else { return PruneResult(removed: 0, kept: 0, mapping: [:]) }
        try commit(Self.externalChanges)
        guard let head = try head() else { return PruneResult(removed: 0, kept: 0, mapping: [:]) }

        struct Entry {
            let hash, tree, message: String
            let time: TimeInterval
            let environment: [String: String]
        }
        let format = "%H%x1f%T%x1f%at%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%B%x1e"
        let entries: [Entry] = try git(["log", "--first-parent", "--reverse", "--format=\(format)"])
            .split(separator: "\u{1e}").compactMap { chunk in
                let f = chunk.drop { $0 == "\n" }.split(separator: "\u{1f}", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { return nil }
                return Entry(hash: String(f[0]), tree: String(f[1]),
                             message: f[9].trimmingCharacters(in: .whitespacesAndNewlines),
                             time: TimeInterval(f[2]) ?? 0,
                             environment: ["GIT_AUTHOR_NAME": String(f[3]), "GIT_AUTHOR_EMAIL": String(f[4]),
                                           "GIT_AUTHOR_DATE": String(f[5]), "GIT_COMMITTER_NAME": String(f[6]),
                                           "GIT_COMMITTER_EMAIL": String(f[7]), "GIT_COMMITTER_DATE": String(f[8])])
            }
        guard entries.last?.hash == head else { throw Failure.command("Der Verlauf ist nicht linear — bitte im Terminal aufräumen.") }

        // Alles vor `split` wird gelöscht; entries[split - 1] liefert den Inhalt des neuen Ausgangsstands.
        let split = cutoff.map { cut in entries.firstIndex { $0.time >= cut.timeIntervalSince1970 } ?? entries.count } ?? entries.count
        // Nichts zu tun, wenn es nur einen Stand gibt bzw. höchstens der erste vor der Grenze liegt.
        guard cutoff == nil ? entries.count > 1 : split > 1 else {
            return PruneResult(removed: 0, kept: entries.count, mapping: [:])
        }
        let base = entries[split - 1]
        let when = Date.now.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_DE")))
        let message = cutoff == nil
            ? "Ausgangsstand (Verlauf am \(when) gelöscht)"
            : "Ausgangsstand (\(split) ältere Stände am \(when) gelöscht)"
        var mapping: [String: String] = [:]
        var parent = try git(["commit-tree", base.tree, "-m", message],
                             environment: cutoff == nil ? [:] : base.environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mapping[base.hash] = parent
        for entry in entries[split...] {
            parent = try git(["commit-tree", entry.tree, "-p", parent, "-m", entry.message], environment: entry.environment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mapping[entry.hash] = parent
        }
        let branch = try git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-ref", "-m", "Verlauf gelöscht", "refs/heads/\(branch)", parent, head])
        // Alte Stände endgültig entfernen.
        _ = try? git(["update-ref", "-d", "ORIG_HEAD"])
        try git(["reflog", "expire", "--expire=now", "--all"])
        try git(["gc", "--prune=now", "--quiet"])
        return PruneResult(removed: split, kept: entries.count - split, mapping: mapping)
    }

    // MARK: git ausführen

    @discardableResult
    private func git(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        guard let gitURL = Self.gitURL else { throw Failure.gitMissing }
        var env = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        env.merge(environment) { _, new in new }
        let result = ProcessRunner.run(gitURL, ["-C", folder.path, "-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments,
                                       environment: env)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.command(message.isEmpty ? "git \(arguments.first ?? "") ist fehlgeschlagen (Code \(result.status))." : message)
        }
        return result.output
    }
}

/// Kurzer, synchroner Prozessaufruf mit getrennter Ausgabe — liest stdout und stderr gleichzeitig,
/// damit große Ausgaben (Diffs) nicht hängen bleiben. Nicht auf dem Main Thread benutzen.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let error: String
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil,
                    environment extra: [String: String] = [:]) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var env = CLIEnvironment.make(for: executable)
        env.merge(extra) { _, new in new }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        let errorData = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outputData, as: UTF8.self),
                      error: String(decoding: errorData.get(), as: UTF8.self))
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        func get() -> Data { lock.withLock { data } }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
