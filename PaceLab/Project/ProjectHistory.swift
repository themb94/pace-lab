import Foundation

/// Version history of the training folder using git. The app records every change as its own commit —
/// coach runs, checkmarks, imported runs, applied plans — so everything can be traced and
/// undone. An actor, so that two git commands never run at the same time.
actor ProjectHistory {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let parents: [String]
        let date: Date
        let subject: String
        let body: String
        let files: [FileStat]

        var shortID: String { String(id.prefix(7)) }
        /// The first commit and merges can't be reverted individually.
        var canRevert: Bool { parents.count == 1 }
    }

    struct FileStat: Hashable, Sendable {
        let path: String
        /// nil for binary files.
        let added: Int?
        let removed: Int?
    }

    enum RevertOutcome: Sendable {
        case reverted(String)
        case nothingToDo
        /// Later changes overlap — only "Reset files" would still work.
        case conflict
    }

    enum Failure: LocalizedError {
        case gitMissing
        case command(String)

        var errorDescription: String? {
            switch self {
            case .gitMissing: String(localized: "git was not found (install Xcode or the Command Line Tools).")
            case .command(let message): message
            }
        }
    }

    /// Message for changes nobody made through the app (e.g. in the chat or by hand).
    static var externalChanges: String { String(localized: "Changes outside the app") }

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

    // MARK: Setup

    /// Creates the repository (if needed), with .gitignore, and records the current state.
    func setUp() throws {
        if !isRepository {
            try git(["init", "-q", "-b", "main"])
        }
        let ignore = folder.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Self.defaultIgnore.write(to: ignore, atomically: true, encoding: .utf8)
        }
        try commit(String(localized: "Initial state"))
    }

    static let defaultIgnore = """
    # macOS
    .DS_Store

    # Python (Garmin server)
    garmin-mcp/.venv/
    __pycache__/
    *.pyc

    # Xcode
    xcuserdata/
    *.xcuserstate
    build/
    DerivedData/

    # Local Claude Code permissions
    .claude/settings.local.json

    """

    // MARK: Recording commits

    /// Records changes as a new commit — all of them or only the given paths.
    /// Returns the new commit, or nil if nothing changed.
    @discardableResult
    func commit(_ message: String, paths: [String]? = nil) throws -> String? {
        guard isRepository else { return nil }
        let changed = try changedPaths(paths)
        guard !changed.isEmpty else { return nil }
        try git(["add", "-A", "--"] + changed)
        try git(["commit", "-q", "--no-verify", "-m", message, "--"] + changed)
        return try head()
    }

    /// Records outside changes and returns the current commit — the starting point of a coach run.
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

    /// Changed paths (including new and deleted files), relative to the folder.
    private func changedPaths(_ paths: [String]?) throws -> [String] {
        let output = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + (paths ?? []))
        var result: [String] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            result.append(String(entry.dropFirst(3)))
            // For renames, the old path follows as its own entry.
            if status.contains("R") || status.contains("C"), let original = entries.popFirst() {
                result.append(original)
            }
        }
        var unique: [String] = []
        for path in result where !unique.contains(path) { unique.append(path) }
        return unique
    }

    // MARK: Reading

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

    /// Differences between a commit and its parent (unified diff).
    func diff(of commit: String) throws -> String {
        try git(["show", "--format=", "--no-color", "--no-ext-diff", "-U3", commit])
    }

    /// Content of a file at a given commit (nil if it didn't exist there).
    func contents(of path: String, at commit: String) -> Data? {
        guard let text = try? git(["show", "\(commit):\(path)"]) else { return nil }
        return Data(text.utf8)
    }

    func changedFiles(from base: String, to target: String) throws -> [String] {
        try git(["diff", "--name-only", "--no-renames", base, target])
            .split(separator: "\n").map(String.init)
    }

    // MARK: Reverting

    /// Reverts the changes of a commit (as a new commit). Later changes elsewhere are kept;
    /// if they overlap, nothing happens and the result is `.conflict`.
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

    /// Resets files to their content in `commit` (files not present there are deleted).
    /// Later changes to these files are lost.
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

    // MARK: Deleting history

    struct PruneResult: Sendable {
        /// Deleted commits.
        let removed: Int
        /// Kept commits (without the new root commit).
        let kept: Int
        /// Old → new hash of the kept commits (for references in coach conversations).
        let mapping: [String: String]
    }

    /// Deletes all commits before `cutoff` (nil = the entire history). The files stay as they are: the most recent
    /// deleted commit becomes the new root commit, later commits are kept with their message and date.
    /// Afterwards git permanently cleans up the old commits — this can't be undone.
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
        guard entries.last?.hash == head else { throw Failure.command(String(localized: "The history is not linear — please clean it up in Terminal.")) }

        // Everything before `split` is deleted; entries[split - 1] provides the content of the new root commit.
        let split = cutoff.map { cut in entries.firstIndex { $0.time >= cut.timeIntervalSince1970 } ?? entries.count } ?? entries.count
        // Nothing to do if there is only one commit or at most the first one lies before the cutoff.
        guard cutoff == nil ? entries.count > 1 : split > 1 else {
            return PruneResult(removed: 0, kept: entries.count, mapping: [:])
        }
        let base = entries[split - 1]
        let when = Date.now.formatted(.dateTime.day().month().year().locale(Fmt.locale))
        let message = cutoff == nil
            ? String(localized: "Initial state (history deleted on \(when))")
            : String(localized: "Initial state (\(split) older versions deleted on \(when))")
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
        try git(["update-ref", "-m", "History deleted", "refs/heads/\(branch)", parent, head])
        // Permanently remove old commits.
        _ = try? git(["update-ref", "-d", "ORIG_HEAD"])
        try git(["reflog", "expire", "--expire=now", "--all"])
        try git(["gc", "--prune=now", "--quiet"])
        return PruneResult(removed: split, kept: entries.count - split, mapping: mapping)
    }

    // MARK: Running git

    @discardableResult
    private func git(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        guard let gitURL = Self.gitURL else { throw Failure.gitMissing }
        var env = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        env.merge(environment) { _, new in new }
        let result = ProcessRunner.run(gitURL, ["-C", folder.path, "-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments,
                                       environment: env)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.command(message.isEmpty ? String(localized: "git \(arguments.first ?? "") failed (code \(result.status)).") : message)
        }
        return result.output
    }
}

/// Short, synchronous process call with separate output — reads stdout and stderr concurrently
/// so that large outputs (diffs) don't get stuck. Don't use on the main thread.
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
