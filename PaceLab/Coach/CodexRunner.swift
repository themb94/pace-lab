import Foundation

/// OpenAI Codex in the background (`codex exec --json`), in the training project folder.
/// Codex can't sign in to Strava — it fetches runs through the watch server (Garmin or Polar), which is
/// therefore always included. Garmin lock: without permission the server starts with GARMIN_READONLY=1
/// and offers no tools for creating/scheduling/deleting; terminal commands run in Codex's
/// sandbox without network (no detour via the token script).
final class CodexRunner: CoachRunner, @unchecked Sendable {
    private let process = CLIProcess()

    func run(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [process] in
                guard let executable = CLIResolver.find(request.engine.command) else {
                    continuation.finish(throwing: CoachError.notFound(request.engine.command))
                    return
                }
                continuation.yield(.started(model: request.engine.model.isEmpty ? nil : request.engine.model, servers: []))
                var parser = CodexStreamParser()
                do {
                    try await parser.stream(process, executable, Self.arguments(for: request),
                                            in: request.workingDirectory, input: request.prompt, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [process] _ in
                task.cancel()
                process.cancel()
            }
        }
    }

    func cancel() { process.cancel() }

    static func arguments(for request: CoachRequest) -> [String] {
        let engine = request.engine
        var args = ["exec", "--json", "--skip-git-repo-check", "--color", "never",
                    "-C", request.workingDirectory.path,
                    "-s", "workspace-write",
                    // Commands in the sandbox without network — even if the Codex configuration says otherwise.
                    "-c", "sandbox_workspace_write.network_access=false"]
        if !engine.model.isEmpty { args += ["-m", engine.model] }
        if !engine.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(engine.effort)\""] }
        args += watchServer(in: request.workingDirectory, watch: request.watch,
                            readOnly: !(request.allowGarminWrite && request.watch.canUpload))
        if request.ephemeral { args.append("--ephemeral") }
        args += ArgumentTemplate.tokenize(engine.arguments)
        if let thread = request.resumeSessionID, !request.ephemeral {
            args += ["resume", thread]
        }
        args.append("-")   // request comes via stdin
        return args
    }

    /// The profile's watch server from the project's .mcp.json as a Codex configuration.
    static func watchServer(in folder: URL, watch: WatchKind, readOnly: Bool) -> [String] {
        guard let name = watch.serverName,
              let data = try? Data(contentsOf: folder.appending(path: ".mcp.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let server = servers[name] as? [String: Any],
              let command = server["command"] as? String else { return [] }
        func toml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let args = (server["args"] as? [String] ?? []).map(toml).joined(separator: ", ")
        var result = ["-c", "mcp_servers.\(name).command=\(toml(command))",
                      "-c", "mcp_servers.\(name).args=[\(args)]",
                      // Nobody can confirm in the background — without permission there are only read tools anyway.
                      "-c", "mcp_servers.\(name).default_tools_approval_mode=\"approve\""]
        var env = server["env"] as? [String: String] ?? [:]
        if readOnly { env["GARMIN_READONLY"] = "1" }
        env["PACELAB_LANG"] = AppLanguage.code
        let pairs = env.sorted { $0.key < $1.key }.map { "\($0.key) = \(toml($0.value))" }.joined(separator: ", ")
        result += ["-c", "mcp_servers.\(name).env={ \(pairs) }"]
        return result
    }
}

/// Translates the JSONL events of `codex exec --json`.
struct CodexStreamParser: OutputParser {
    private var done = false
    private var lastError: String?
    private var startedItems: Set<String> = []

    mutating func parse(_ line: String) -> [CoachEvent] {
        guard line.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }

        switch type {
        case "thread.started":
            return (object["thread_id"] as? String).map { [.session($0)] } ?? []

        case "item.started":
            guard let item = object["item"] as? [String: Any], let id = item["id"] as? String,
                  let label = Self.label(for: item) else { return [] }
            startedItems.insert(id)
            return [.toolStarted(id: id, name: item["type"] as? String ?? "", label: label)]

        case "item.completed":
            guard let item = object["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                guard let text = item["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return [.text(text)]
            case "error":
                // Mostly hints (e.g. missing model metadata) — only remember them for the error case.
                lastError = item["message"] as? String
                return []
            default:
                guard let label = Self.label(for: item) else { return [] }
                let failed = Self.failed(item)
                if startedItems.contains(id) { return [.toolFinished(id: id, failed: failed)] }
                return [.toolStarted(id: id, name: item["type"] as? String ?? "", label: label),
                        .toolFinished(id: id, failed: failed)]
            }

        case "turn.completed":
            done = true
            return [.finished(CoachResult(isError: false, message: nil))]

        case "turn.failed":
            done = true
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.finished(CoachResult(isError: true, message: Self.readable(message ?? lastError)))]

        case "error":
            lastError = object["message"] as? String
            return []

        default:
            return []
        }
    }

    mutating func finish(_ outcome: CLIProcess.Outcome) -> CoachEvent? {
        if done { return nil }
        if outcome.signaled { return .finished(CoachResult(isError: true, message: "Abgebrochen.")) }
        let message = Self.readable(lastError) ?? (outcome.stderr.isEmpty
            ? String(localized: "Codex quit unexpectedly (code \(outcome.exitCode)).")
            : String(localized: "Codex reports: \(outcome.stderr)"))
        return .finished(CoachResult(isError: true, message: message))
    }

    // MARK: Helpers

    private static func label(for item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "command_execution":
            return String(localized: "Command: \(shortCommand(item["command"] as? String ?? ""))")
        case "mcp_tool_call":
            return ToolLabel.label(server: item["server"] as? String ?? "MCP", tool: item["tool"] as? String ?? "")
        case "file_change":
            let files = (item["changes"] as? [[String: Any]] ?? [])
                .compactMap { ($0["path"] as? String).map { URL(filePath: $0).lastPathComponent } }
            return files.isEmpty ? String(localized: "Editing files") : String(localized: "Editing \(files.joined(separator: ", "))")
        case "web_search":
            return String(localized: "Web search: \(item["query"] as? String ?? "")")
        default:
            return nil   // don't show thinking, task lists etc. as a step
        }
    }

    private static func failed(_ item: [String: Any]) -> Bool {
        if let status = item["status"] as? String, status == "failed" || status == "declined" { return true }
        if let code = item["exit_code"] as? Int { return code != 0 }
        return false
    }

    /// `/bin/zsh -lc "sed -n '1,220p' plan.json"` → `sed -n '1,220p' plan.json`
    private static func shortCommand(_ command: String) -> String {
        var c = command
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where c.hasPrefix(shell) {
            c = String(c.dropFirst(shell.count))
            if c.count >= 2, let first = c.first, first == c.last, first == "\"" || first == "'" {
                c = String(c.dropFirst().dropLast())
            }
        }
        return c.count > 80 ? String(c.prefix(79)) + "…" : c
    }

    /// Codex often delivers API errors as JSON in the text — extract the actual message.
    private static func readable(_ message: String?) -> String? {
        guard let message else { return nil }
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (json["error"] as? [String: Any])?["message"] as? String {
            return inner
        }
        return message
    }
}
