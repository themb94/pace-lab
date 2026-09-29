import Foundation

// MARK: - Anfrage & Ereignisse (für alle Engines gleich)

struct CoachRequest: Sendable {
    var engine: CoachEngine
    var workingDirectory: URL
    /// Fertig zusammengesetzter Text (bei Text-CLIs inkl. Trainingsstand und Verlauf).
    var prompt: String
    var systemPrompt: String
    /// Session der Engine zum Fortsetzen (Claude: Session-ID, Codex: Thread-ID); nil = neu.
    var resumeSessionID: String?
    /// Claude Code: ID für eine neue Session.
    var newSessionID: UUID
    var sessionName: String
    /// Nur dann dürfen Garmin-Workouts angelegt, eingeplant oder gelöscht werden.
    var allowGarminWrite: Bool
    /// Nichts dauerhaft speichern (Test in den Einstellungen).
    var ephemeral = false
}

struct McpStatus: Sendable, Hashable, Codable {
    var name: String
    var status: String

    var isConnected: Bool { status == "connected" }
}

enum CoachEvent: Sendable {
    case started(model: String?, servers: [McpStatus])
    /// Session-/Thread-ID der Engine, mit der das Gespräch fortgesetzt wird.
    case session(String)
    /// Ein vollständiger Antwort-Absatz (Agenten).
    case text(String)
    /// Gestreamter Antworttext (Text-CLIs) — wird an den laufenden Block angehängt.
    case textDelta(String)
    case toolStarted(id: String, name: String, label: String)
    case toolFinished(id: String, failed: Bool)
    case rateLimited(String)
    case finished(CoachResult)
}

struct CoachResult: Sendable {
    var isError: Bool
    var message: String?
    /// Werkzeuge, die mangels Freigabe nicht laufen durften (Tool-Namen).
    var deniedTools: [String] = []
    var durationSeconds: Double? = nil
}

enum CoachError: LocalizedError {
    case notFound(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let command):
            "„\(command)“ wurde nicht gefunden. Trag in den Einstellungen → Coach den vollständigen Pfad ein."
        case .launchFailed(let reason):
            "Die CLI ließ sich nicht starten: \(reason)"
        }
    }
}

protocol CoachRunner: AnyObject, Sendable {
    func run(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, any Error>
    func cancel()
}

enum CoachRunners {
    static func make(for kind: CoachEngine.Kind) -> any CoachRunner {
        switch kind {
        case .claudeCode: ClaudeCodeRunner()
        case .codex: CodexRunner()
        case .textCLI: TextCLIRunner()
        }
    }
}

/// Übersetzt die Ausgabe einer CLI Zeile für Zeile in CoachEvents.
protocol OutputParser {
    mutating func parse(_ line: String) -> [CoachEvent]
    /// Nach Prozessende: Abschluss-Ereignis, falls die CLI selbst keins geliefert hat.
    mutating func finish(_ outcome: CLIProcess.Outcome) -> CoachEvent?
}

extension OutputParser {
    /// Startet einen Prozess und reicht seine Ereignisse an `continuation` weiter.
    mutating func stream(_ process: CLIProcess, _ executable: URL, _ arguments: [String], in directory: URL,
                         input: String?, to continuation: AsyncThrowingStream<CoachEvent, any Error>.Continuation) async throws {
        let lines = try process.start(executable, arguments, in: directory, input: input)
        for await line in lines {
            for event in parse(line) { continuation.yield(event) }
        }
        let outcome = await process.waitForExit()
        if let final = finish(outcome) { continuation.yield(final) }
    }
}

// MARK: - Prozess

/// Ein CLI-Aufruf: startet das Programm, liefert stdout zeilenweise, sammelt stderr.
final class CLIProcess: @unchecked Sendable {
    struct Outcome: Sendable {
        let exitCode: Int32
        let signaled: Bool
        let stderr: String
    }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private let errorTail = LockedText()
    private var exited: AsyncStream<Void>?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func start(_ executable: URL, _ arguments: [String], in directory: URL, input: String?) throws -> AsyncStream<String> {
        let out = Pipe(), err = Pipe()
        let inPipe: Pipe? = input == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = CLIEnvironment.make(for: executable)
        process.standardInput = inPipe ?? FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        let errorTail = self.errorTail
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorTail.append(data) }
        }
        let splitter = LineSplitter()
        let lines = AsyncStream<String> { continuation in
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = splitter.flush() { continuation.yield(rest) }
                    continuation.finish()
                } else {
                    for line in splitter.feed(data) { continuation.yield(line) }
                }
            }
        }
        exited = AsyncStream { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }

        guard !isCancelled else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw CoachError.launchFailed(error.localizedDescription)
        }
        if let inPipe, let input {
            // (SIGPIPE ist beim App-Start abgeschaltet, falls der Prozess sofort wieder endet.)
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        return lines
    }

    func waitForExit() async -> Outcome {
        if let exited { for await _ in exited {} }
        return Outcome(exitCode: process.terminationStatus,
                       signaled: process.terminationReason == .uncaughtSignal || isCancelled,
                       stderr: errorTail.tail())
    }

    func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }
}

/// Zerlegt Byte-Blöcke in Zeilen — leere Zeilen bleiben erhalten (wichtig für Markdown).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }

    func flush() -> String? {
        lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }
}

/// Behält die letzten Zeilen von stderr für Fehlermeldungen (ohne bekanntes Rauschen).
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 16_000 { data = data.suffix(8_000) }
        }
    }

    func tail() -> String {
        lock.withLock {
            ANSI.strip(String(decoding: data, as: UTF8.self))
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    !line.isEmpty
                        && !line.contains("no stdin data received")
                        && !line.contains("Reading additional input from stdin")
                        && !line.contains("rmcp::")
                }
                .suffix(4)
                .joined(separator: "\n")
        }
    }
}

enum ANSI {
    /// Entfernt Farb-/Cursor-Steuerzeichen; bei \r gilt (wie im Terminal) nur der letzte Teil.
    static func strip(_ text: String) -> String {
        let withoutCodes = text
            .replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
            .replacing(/\u{1B}\][^\u{07}]*\u{07}/, with: "")
        return withoutCodes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.split(separator: "\r", omittingEmptySubsequences: false).last ?? "") }
            .joined(separator: "\n")
    }
}

// MARK: - Programme finden & Umgebung

enum CLIResolver {
    /// Übliche Installationsorte — GUI-Apps kennen den PATH der Shell nicht.
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.lmstudio/bin",
                "\(home)/.npm-global/bin", "\(home)/.claude/local", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                // LM-Studio-CLI, wie sie Bionic bzw. LM Studio mitbringen
                "/Applications/Bionic.app/Contents/Resources/app/.webpack-bionic",
                "/Applications/LM Studio.app/Contents/Resources/app/.webpack"]
    }

    /// Pfad (auch mit ~) oder Befehlsname → ausführbare Datei.
    static func find(_ command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(filePath: expanded) : nil
        }
        for dir in searchDirectories {
            let path = "\(dir)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(filePath: path) }
        }
        // Letzter Versuch: die Login-Shell fragen.
        let quoted = "'" + expanded.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let output = runSync(URL(filePath: "/bin/zsh"), ["-lc", "command -v \(quoted)"])
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
    }

    /// Kurzer, synchroner Aufruf (Version, Modell-Liste) — nicht auf dem Main Thread benutzen.
    static func runSync(_ executable: URL, _ arguments: [String], in directory: URL? = nil) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLIEnvironment.make(for: executable)
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum CLIEnvironment {
    /// Umgebung der App plus die üblichen Programmordner im PATH. Variablen einer umgebenden
    /// Claude-Code-Sitzung werden entfernt, damit jede CLI ihr eigenes Login nutzt.
    static func make(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") || key.hasPrefix("MCP_"))
        }
        var path: [String] = []
        for dir in [executable.deletingLastPathComponent().path] + CLIResolver.searchDirectories where !path.contains(dir) {
            path.append(dir)
        }
        env["PATH"] = path.joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        return env
    }
}
