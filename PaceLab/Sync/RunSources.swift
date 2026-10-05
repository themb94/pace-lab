import Foundation

/// Fortschritt für die Anzeige, z. B. „Garmin: Lauf-Details (1/2)“.
typealias SyncProgress = @Sendable (String) -> Void

struct SyncFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Garmin (direkt)

/// Läufe direkt vom lokalen Garmin-Server — nur lesend und ohne Sprachmodell.
struct GarminRunSource: Sendable {
    let folder: URL

    func fetch(since: String, known: KnownRuns, progress: SyncProgress) async throws -> [ImportedRun] {
        guard let config = GarminServerConfig.load(from: folder) else {
            throw SyncFailure(message: String(localized: "No Garmin server set up: the training folder has no .mcp.json with “garmin-workouts”."))
        }
        progress(String(localized: "Garmin: connecting"))
        let client = try await config.connect(in: folder, readOnly: true)
        return try await withTaskCancellationHandler {
            defer { client.close() }
            progress(String(localized: "Garmin: fetching activities"))
            let list = try Self.checked(try await client.callTool(
                "list_activities", arguments: ["limit": 30, "activity_type": "running"]))
            guard let activities = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]] else {
                throw SyncFailure(message: String(localized: "Garmin: unexpected response to list_activities."))
            }

            var candidates: [(id: String, name: String)] = []
            for activity in activities.reversed() {   // älteste zuerst
                guard let id = RunImport.stringID(activity["activityId"]),
                      let start = activity["startTimeLocal"] as? String else { continue }
                let date = String(start.prefix(10))
                let km = (RunImport.number(activity["distance_m"]) ?? 0) / 1000
                guard date >= since, km >= 0.5,
                      !known.contains(source: .garmin, id: id, date: date, distanceKm: km) else { continue }
                candidates.append((id, activity["activityName"] as? String ?? String(localized: "Run")))
            }

            var runs: [ImportedRun] = []
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                progress("Garmin: \(candidate.name) (\(index + 1)/\(candidates.count))")
                let text = try Self.checked(try await client.callTool(
                    "get_activity_data", arguments: ["activity_id": candidate.id]))
                guard let detail = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let run = RunImport.garmin(detail) else { continue }
                runs.append(run)
            }
            return runs
        } onCancel: {
            client.close()
        }
    }

    /// Der Garmin-Server meldet Fehler als Text, der mit „❌“ beginnt.
    private static func checked(_ text: String) throws -> String {
        guard text.hasPrefix("❌") else { return text }
        let message = text.dropFirst().trimmingCharacters(in: .whitespaces)
        throw SyncFailure(message: String(localized: "Garmin reports: \(message)\nIf the sign-in has expired, run “./.venv/bin/python login.py” in the garmin-mcp folder in Terminal."))
    }
}

// MARK: - Strava (über Claude Code)

/// Strava lässt sich nur über den Strava-MCP in Claude Code erreichen. Claude ruft dafür im Hintergrund
/// nur die beiden Lese-Werkzeuge auf; die App übernimmt die Rohdaten direkt aus dem Stream — Zahlen
/// gehen also nicht durch das Modell.
struct StravaViaClaudeSource: Sendable {
    let folder: URL
    /// Claude-Programm (wie beim Coach).
    let command: String
    let model: String

    static let tools = ["mcp__strava-mcp__list_activities", "mcp__strava-mcp__get_activity_performance"]
    private static let runTypes: Set<String> = ["Run", "TrailRun", "VirtualRun"]

    func fetch(since: String, knownIDs: [String], known: KnownRuns, progress: SyncProgress) async throws -> [ImportedRun] {
        guard let claude = CLIResolver.find(command) else { throw CoachError.notFound(command) }
        let skip = knownIDs.isEmpty ? "" : " — except for these already known IDs: \(knownIDs.joined(separator: ", "))"
        let prompt = """
        1. Call mcp__strava-mcp__list_activities with first=30 and range_start="\(since)T00:00:00".
        2. For every activity with sport_type Run, TrailRun or VirtualRun, call mcp__strava-mcp__get_activity_performance with its id as activity_id\(skip). Several calls at once are fine.
        3. If there is nothing new, make no further calls. At the end, reply only with: done
        """
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--tools", "",
            "--allowedTools", Self.tools.joined(separator: ","),
            "--permission-prompts", "none",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--system-prompt", "You fetch run data through the Strava tools. Make exactly the calls described and then reply only with: done",
        ]
        if !model.isEmpty { arguments += ["--model", model] }

        // Claude Code verbindet den Strava-Server asynchron; war er beim Start noch nicht bereit
        // und kam deshalb nichts zurück, einmal neu versuchen.
        var parser = StravaStreamParser()
        for attempt in 1...2 {
            progress(attempt == 1 ? String(localized: "Strava: starting Claude Code") : String(localized: "Strava: second attempt"))
            parser = StravaStreamParser()
            let process = CLIProcess()
            let outcome = try await withTaskCancellationHandler {
                let lines = try process.start(claude, arguments, in: folder, input: prompt)
                for await line in lines {
                    if let step = parser.parse(line) { progress(step) }
                }
                return await process.waitForExit()
            } onCancel: {
                process.cancel()
            }
            try Task.checkCancellation()
            if attempt == 1 && parser.shouldRetry { continue }
            try parser.check(outcome)
            break
        }

        var runs: [ImportedRun] = []
        var missing = 0
        for activity in parser.activities {
            guard let type = activity["sport_type"] as? String, Self.runTypes.contains(type),
                  let id = RunImport.stringID(activity["id"]),
                  let start = activity["start_local"] as? String else { continue }
            let date = String(start.prefix(10))
            let km = (RunImport.number((activity["summary"] as? [String: Any])?["distance"]) ?? 0) / 1000
            guard date >= since, km >= 0.5, !known.contains(source: .strava, id: id, date: date, distanceKm: km) else { continue }
            guard let performance = parser.performances[id] else {
                missing += 1   // beim nächsten Laden erneut versuchen
                continue
            }
            if let run = RunImport.strava(activity, performance: performance) { runs.append(run) }
        }
        if runs.isEmpty && missing > 0 {
            throw SyncFailure(message: String(localized: "Strava: found \(missing) new runs, but without details — please load again."))
        }
        return runs
    }
}

/// Liest aus dem Stream von Claude Code die Rohantworten der Strava-Werkzeuge.
struct StravaStreamParser {
    private(set) var activities: [[String: Any]] = []
    private(set) var performances: [String: [String: Any]] = [:]
    private var calls: [String: (tool: String, activityID: String?)] = [:]
    private var stravaStatus: String?
    private var resultError: String?
    private var sawResult = false
    private var denied: [String] = []
    private var limitReached = false
    private var detailCount = 0

    /// Verarbeitet eine Zeile und liefert ggf. einen Fortschrittstext.
    mutating func parse(_ line: String) -> String? {
        guard line.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return nil }
            let servers = object["mcp_servers"] as? [[String: Any]] ?? []
            stravaStatus = servers.first { $0["name"] as? String == "strava-mcp" }?["status"] as? String ?? "missing"
            return String(localized: "Strava: connecting")

        case "assistant":
            var step: String?
            for block in (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                      let tool = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                calls[id] = (tool, RunImport.stringID(input["activity_id"]))
                if tool.hasSuffix("list_activities") {
                    step = String(localized: "Strava: fetching activities")
                } else {
                    detailCount += 1
                    step = String(localized: "Strava: run details (\(detailCount))")
                }
            }
            return step

        case "user":
            for block in (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                      let call = calls[id], block["is_error"] as? Bool != true else { continue }
                let text: String
                if let string = block["content"] as? String {
                    text = string
                } else {
                    text = (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                }
                guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                if call.tool.hasSuffix("list_activities") {
                    activities += json["activities"] as? [[String: Any]] ?? []
                } else if let activityID = call.activityID {
                    performances[activityID] = json
                }
            }
            return nil

        case "result":
            sawResult = true
            if object["is_error"] as? Bool == true {
                resultError = object["result"] as? String ?? String(localized: "Claude Code reports an error.")
            }
            denied = (object["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
            return nil

        case "rate_limit_event":
            let info = object["rate_limit_info"] as? [String: Any]
            if info?["status"] as? String == "rejected" { limitReached = true }
            return nil

        default:
            return nil
        }
    }

    /// Strava war beim Start noch nicht verbunden und es kam nichts zurück.
    var shouldRetry: Bool {
        activities.isEmpty && !limitReached && stravaStatus != nil && stravaStatus != "connected" && stravaStatus != "failed"
            && stravaStatus != "needs-auth" && stravaStatus != "missing"
    }

    /// Wirft eine verständliche Meldung, wenn der Abruf nicht geklappt hat.
    func check(_ outcome: CLIProcess.Outcome) throws {
        if outcome.signaled { throw CancellationError() }
        if limitReached {
            throw SyncFailure(message: String(localized: "Strava: your Claude usage limit has been reached — load again later or choose Garmin as the source."))
        }
        if activities.isEmpty, let status = stravaStatus, status != "connected" {
            throw SyncFailure(message: String(localized: "Strava is not connected in Claude Code (status: \(status)). In Terminal, start “claude” in the training folder and sign in to “strava-mcp” under /mcp."))
        }
        if let resultError { throw SyncFailure(message: "Strava: \(resultError)") }
        if !sawResult {
            throw SyncFailure(message: outcome.stderr.isEmpty
                ? String(localized: "Claude Code quit unexpectedly (code \(outcome.exitCode)).")
                : String(localized: "Claude Code reports: \(outcome.stderr)"))
        }
        if activities.isEmpty && !denied.isEmpty {
            throw SyncFailure(message: String(localized: "Strava: Claude was not allowed to use the tools (\(denied.joined(separator: ", ")))."))
        }
    }
}
