import Foundation

/// Der lokale Garmin-MCP-Server, wie er in der .mcp.json des Projekts eingetragen ist.
struct GarminServerConfig: Sendable {
    let command: String
    let arguments: [String]
    let environment: [String: String]

    static func load(from folder: URL) -> GarminServerConfig? {
        guard let data = try? Data(contentsOf: folder.appending(path: ".mcp.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let garmin = servers["garmin-workouts"] as? [String: Any],
              let command = garmin["command"] as? String else { return nil }
        return GarminServerConfig(command: command,
                                  arguments: garmin["args"] as? [String] ?? [],
                                  environment: garmin["env"] as? [String: String] ?? [:])
    }

    /// Startet den Server und meldet sich an. `readOnly`: ohne Werkzeuge zum Anlegen/Löschen.
    func connect(in folder: URL, readOnly: Bool, extraEnvironment: [String: String] = [:]) async throws -> MCPClient {
        guard let executable = CLIResolver.find(command) else { throw CoachError.notFound(command) }
        var env = environment.merging(extraEnvironment) { _, new in new }
        if readOnly { env["GARMIN_READONLY"] = "1" }
        let client = MCPClient(executable: executable, arguments: arguments, environment: env, directory: folder)
        try await client.start()
        return client
    }
}

/// Minimaler MCP-Client über stdio (JSON-RPC 2.0, eine Nachricht pro Zeile). Damit ruft die App
/// Werkzeuge des Garmin-Servers direkt auf — ohne Sprachmodell dazwischen.
final class MCPClient: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let splitter = LineSplitter()
    private let errorTail = LockedText()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var finished = false

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = CLIEnvironment.make(for: executable)
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    deinit { close() }

    func start() async throws {
        errors.fileHandleForReading.readabilityHandler = { [errorTail] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorTail.append(data) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in self.splitter.feed(data) { self.receive(line) }
        }
        process.terminationHandler = { [weak self] _ in self?.failAll() }
        do {
            try process.run()
        } catch {
            throw CoachError.launchFailed(error.localizedDescription)
        }
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: String](),
            "clientInfo": ["name": "Pace Lab", "version": "1.0"],
        ], timeout: 30)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// Ruft ein Werkzeug auf und liefert seine Textantwort.
    func callTool(_ name: String, arguments: [String: any Sendable] = [:], timeout: TimeInterval = 120) async throws -> String {
        let data = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = message["result"] as? [String: Any] else {
            throw Failure(message: "Unerwartete Antwort von \(name).")
        }
        let text = (result["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        if result["isError"] as? Bool == true {
            throw Failure(message: text.isEmpty ? "\(name) ist fehlgeschlagen." : text)
        }
        return text
    }

    func close() {
        lock.withLock { finished = true }
        if process.isRunning {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
        failAll()
    }

    // MARK: Nachrichten

    private func request(_ method: String, params: [String: any Sendable], timeout: TimeInterval) async throws -> Data {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock { () -> Bool in
                guard !finished else { return false }
                pending[id] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: Failure(message: stoppedMessage))
                return
            }
            do {
                try write(payload)
            } catch {
                resume(id, with: .failure(Failure(message: stoppedMessage)))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resume(id, with: .failure(Failure(message: "Der Garmin-Server antwortet nicht (\(method), \(Int(timeout)) s).")))
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        try write(try JSONSerialization.data(withJSONObject: message))
    }

    private func write(_ payload: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: payload + Data([0x0A]))
    }

    private func receive(_ line: String) {
        guard line.first == "{", let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            // Anfrage des Servers (z. B. ping) höflich beantworten; Benachrichtigungen ignorieren.
            guard let id = message["id"] else { return }
            let reply: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [String: String]()]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Nicht unterstützt"]]
            try? send(reply)
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue else { return }
        if let error = message["error"] as? [String: Any] {
            resume(id, with: .failure(Failure(message: error["message"] as? String ?? "Fehler vom Garmin-Server.")))
        } else {
            resume(id, with: .success(data))
        }
    }

    private func resume(_ id: Int, with result: Result<Data, any Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Data, any Error>] in
            finished = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        let message = stoppedMessage
        for continuation in waiting { continuation.resume(throwing: Failure(message: message)) }
    }

    private var stoppedMessage: String {
        let tail = errorTail.tail()
        return tail.isEmpty ? "Der Garmin-Server wurde beendet." : "Der Garmin-Server wurde beendet: \(tail)"
    }
}
