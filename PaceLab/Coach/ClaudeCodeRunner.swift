import Foundation

/// Claude Code in the background (`claude -p`), in the training project folder —
/// with the same README, the same memory and the same MCP servers as in the chat.
final class ClaudeCodeRunner: CoachRunner, @unchecked Sendable {
    private let process = CLIProcess()

    static let garminReadTools = [
        "mcp__garmin-workouts__garmin_status",
        "mcp__garmin-workouts__list_activities",
        "mcp__garmin-workouts__get_activity_data",
        "mcp__garmin-workouts__list_workouts",
        "mcp__garmin-workouts__preview_plan",
    ]
    static let garminWriteTools = [
        "mcp__garmin-workouts__create_plan",
        "mcp__garmin-workouts__schedule_workout",
        "mcp__garmin-workouts__delete_workout",
    ]

    func run(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [process] in
                guard let executable = CLIResolver.find(request.engine.command) else {
                    continuation.finish(throwing: CoachError.notFound(request.engine.command))
                    return
                }
                var parser = ClaudeStreamParser()
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
        var allowed = ["Read", "Glob", "Grep", "Edit", "Write", "MultiEdit", "WebSearch", "WebFetch", "TodoWrite",
                       "mcp__strava-mcp"] + request.watch.readTools
        var disallowed: [String] = []
        if request.allowGarminWrite && request.watch.canUpload {
            allowed += garminWriteTools
        } else {
            // Without permission, neither Garmin write access nor the terminal (token script as a detour).
            disallowed += garminWriteTools + ["Bash"]
        }

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            // The coach may change files in the project; everything else unapproved is rejected instead of asking.
            "--permission-mode", "acceptEdits",
            "--permission-prompts", "none",
            "--append-system-prompt", request.systemPrompt,
            "--allowedTools", allowed.joined(separator: ","),
        ]
        if !disallowed.isEmpty {
            args += ["--disallowedTools", disallowed.joined(separator: ",")]
        }
        // In -p mode the CLI only loads the project's .mcp.json (Garmin) if it is named explicitly.
        let mcpConfig = request.workingDirectory.appending(path: ".mcp.json")
        if FileManager.default.fileExists(atPath: mcpConfig.path) {
            args += ["--mcp-config", mcpConfig.path]
        }
        if let memory = memoryDirectory(for: request.workingDirectory) {
            args += ["--add-dir", memory.path]
        }
        let engine = request.engine
        if !engine.model.isEmpty { args += ["--model", engine.model] }
        if !engine.effort.isEmpty { args += ["--effort", engine.effort] }
        args += ArgumentTemplate.tokenize(engine.arguments)

        if request.ephemeral {
            args.append("--no-session-persistence")
        } else if let resume = request.resumeSessionID {
            args += ["--resume", resume]
        } else {
            args += ["--session-id", request.newSessionID.uuidString.lowercased(), "--name", request.sessionName]
        }
        return args
    }

    /// Claude Code's memory for this folder (~/.claude/projects/<path with - instead of />/memory,
    /// or in the profile's own configuration).
    static func memoryDirectory(for folder: URL) -> URL? {
        let key = String(folder.standardizedFileURL.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let url = ActiveProfile.current.claudeHome
            .appending(path: "projects/\(key)/memory", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Translates `--output-format stream-json` from Claude Code.
struct ClaudeStreamParser: OutputParser {
    private var sawResult = false

    mutating func parse(_ line: String) -> [CoachEvent] {
        guard line.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }

        // Don't show sub-agents' messages individually.
        if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return [] }
            let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap { entry -> McpStatus? in
                guard let name = entry["name"] as? String, let status = entry["status"] as? String else { return nil }
                return McpStatus(name: name, status: status)
            }
            var events: [CoachEvent] = [.started(model: object["model"] as? String, servers: servers)]
            if let session = object["session_id"] as? String { events.append(.session(session)) }
            return events

        case "assistant":
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return .text(text)
                case "tool_use":
                    let name = block["name"] as? String ?? String(localized: "Tool")
                    let input = block["input"] as? [String: Any] ?? [:]
                    return .toolStarted(id: block["id"] as? String ?? UUID().uuidString,
                                        name: name, label: ToolLabel.describe(name, input: input))
                default:
                    return nil
                }
            }

        case "user":
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id, failed: block["is_error"] as? Bool ?? false)
            }

        case "result":
            sawResult = true
            let denied = (object["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
            var unique: [String] = []
            for name in denied where !unique.contains(name) { unique.append(name) }
            return [.finished(CoachResult(
                isError: object["is_error"] as? Bool ?? false,
                message: object["result"] as? String,
                deniedTools: unique,
                durationSeconds: (object["duration_ms"] as? Double).map { $0 / 1000 }
            ))]

        case "rate_limit_event":
            let info = object["rate_limit_info"] as? [String: Any]
            guard let status = info?["status"] as? String, status != "allowed" else { return [] }
            return [.rateLimited(status)]

        default:
            return []
        }
    }

    mutating func finish(_ outcome: CLIProcess.Outcome) -> CoachEvent? {
        if sawResult { return nil }
        if outcome.signaled { return .finished(CoachResult(isError: true, message: "Abgebrochen.")) }
        let message = outcome.stderr.isEmpty
            ? String(localized: "Claude Code quit unexpectedly (code \(outcome.exitCode)).")
            : String(localized: "Claude Code reports: \(outcome.stderr)")
        return .finished(CoachResult(isError: true, message: message))
    }
}

/// Readable description of a tool call.
enum ToolLabel {
    static func describe(_ name: String, input: [String: Any]) -> String {
        func fileName(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(filePath: $0).lastPathComponent } ?? ""
        }
        switch name {
        case "Read": return String(localized: "Reading \(fileName())")
        case "Edit", "MultiEdit": return String(localized: "Editing \(fileName())")
        case "Write": return String(localized: "Writing \(fileName())")
        case "Glob", "Grep": return String(localized: "Searching the project")
        case "WebSearch": return String(localized: "Web search: \(input["query"] as? String ?? "")")
        case "WebFetch": return String(localized: "Loading \(URL(string: input["url"] as? String ?? "")?.host() ?? String(localized: "a web page"))")
        case "TodoWrite": return String(localized: "Planning next steps")
        case "ToolSearch": return String(localized: "Loading tools")
        case "Task", "Agent": return String(localized: "Subtask: \(input["description"] as? String ?? "")")
        case "Bash": return "Terminal: \((input["command"] as? String ?? "").prefix(60))"
        default: return label(for: name)
        }
    }

    static func label(for tool: String) -> String {
        let known = [
            "mcp__strava-mcp__list_activities": String(localized: "Strava: fetching activities"),
            "mcp__strava-mcp__get_activity_performance": String(localized: "Strava: run details"),
            "mcp__strava-mcp__get_activity_streams": String(localized: "Strava: time series (pace/HR)"),
            "mcp__strava-mcp__get_athlete_zones": String(localized: "Strava: HR zones"),
            "mcp__strava-mcp__get_athlete_profile": String(localized: "Strava: profile"),
            "mcp__garmin-workouts__garmin_status": String(localized: "Garmin: checking connection"),
            "mcp__garmin-workouts__list_activities": String(localized: "Garmin: fetching activities"),
            "mcp__garmin-workouts__get_activity_data": String(localized: "Garmin: run details"),
            "mcp__garmin-workouts__list_workouts": String(localized: "Garmin: listing workouts"),
            "mcp__garmin-workouts__preview_plan": String(localized: "Garmin: previewing the week"),
            "mcp__garmin-workouts__create_plan": String(localized: "Garmin: creating workouts"),
            "mcp__garmin-workouts__schedule_workout": String(localized: "Garmin: scheduling a workout"),
            "mcp__garmin-workouts__delete_workout": String(localized: "Garmin: deleting a workout"),
            "mcp__polar__polar_status": String(localized: "Polar: checking connection"),
            "mcp__polar__list_activities": String(localized: "Polar: fetching activities"),
            "mcp__polar__get_activity_data": String(localized: "Polar: run details"),
            "mcp__polar__preview_plan": String(localized: "Polar: previewing the week"),
        ]
        if let label = known[tool] { return label }
        for (prefix, title) in [("mcp__strava-mcp__", "Strava"), ("mcp__garmin-workouts__", "Garmin"), ("mcp__polar__", "Polar")] where tool.hasPrefix(prefix) {
            return "\(title): \(tool.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " "))"
        }
        return tool
    }

    /// For engines that report MCP calls as (server, tool) (Codex).
    static func label(server: String, tool: String) -> String {
        let s = server.lowercased()
        if s.contains("strava") { return label(for: "mcp__strava-mcp__\(tool)") }
        if s.contains("garmin") { return label(for: "mcp__garmin-workouts__\(tool)") }
        if s.contains("polar") { return label(for: "mcp__polar__\(tool)") }
        return "\(server): \(tool.replacingOccurrences(of: "_", with: " "))"
    }
}
