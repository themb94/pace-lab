import Foundation

/// Eine Planungsanfrage an den Coach — Woche umbauen, Einheit ändern oder neuen Block entwerfen.
struct PlanRequest: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable, Codable, Sendable {
        case week, session, block

        var id: String { rawValue }

        var label: String {
            switch self {
            case .week: String(localized: "Adjust week")
            case .session: String(localized: "Change session")
            case .block: String(localized: "Plan new block")
            }
        }

        var symbol: String {
            switch self {
            case .week: "calendar.badge.clock"
            case .session: "slider.horizontal.3"
            case .block: "calendar.badge.plus"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var week: Int
    var sessionID: String?
    /// Freitext: Anlass bzw. Wunsch („Stadtlauf am Samstag“, „Knie zwickt“ …).
    var details = ""

    // Neuer Block
    var goal = ""
    var hasRace = false
    var raceDate: Date
    var start: Date
    var weeks = 12
    var runsPerWeek = 3

    init(kind: Kind, snapshot: TrainingSnapshot?, week: Int? = nil, sessionID: String? = nil, today: Date = .now) {
        self.kind = kind
        self.sessionID = sessionID
        let focus = snapshot?.focusWeek(on: today) ?? 1
        self.week = week ?? focus
        // Neuer Block: Montag nach dem Ende des aktuellen Blocks (oder nächster Montag, wenn der vorbei ist).
        let nextMonday = DateUtil.calendar.date(byAdding: .day, value: 7, to: DateUtil.startOfWeek(today))!
        if let snapshot {
            let afterBlock = DateUtil.calendar.date(byAdding: .day, value: 1, to: snapshot.sunday(ofWeek: snapshot.weekCount))!
            start = max(afterBlock, nextMonday)
            runsPerWeek = snapshot.plan.weeks.first?.sessions.count ?? 3
        } else {
            start = nextMonday
        }
        raceDate = DateUtil.calendar.date(byAdding: .day, value: 7 * 12 - 1, to: start)!
    }

    static func == (lhs: PlanRequest, rhs: PlanRequest) -> Bool { lhs.id == rhs.id }
}

/// Texte, mit denen der Coach plant. Agenten ändern plan.json bzw. schreiben plan-entwurf.json selbst;
/// reine Text-CLIs antworten mit einem JSON-Vorschlag, den die App nach Bestätigung übernimmt.
enum PlanPrompts {
    static func title(for request: PlanRequest, snapshot: TrainingSnapshot) -> String {
        switch request.kind {
        case .week: return String(localized: "Adjust week \(request.week)")
        case .session:
            guard let session = request.sessionID.flatMap(snapshot.session(id:)) else { return String(localized: "Change session") }
            return String(localized: "Change W\(session.week) · \(session.kind.label)")
        case .block: return String(localized: "Plan new block")
        }
    }

    // MARK: Agenten (Claude Code, Codex)

    static func agentPrompt(for request: PlanRequest, snapshot: TrainingSnapshot) -> String {
        switch request.kind {
        case .week, .session:
            return String(localized: """
            \(task(request, snapshot))

            Change plan.json directly for this: the affected sessions (type, dist, desc) and, matching each, its “workout” \
            (schema: README, section “Plan schema” — garmin_workouts.py builds the Garmin workouts from it, so don’t change anything there). \
            Only adjust other weeks if this change really requires it, and explain why. The ticks are tied to the \
            type and position of a session ({idPrefix}w{week}-{type}-{index}) — so don’t change type or order of sessions that are already ticked off. \
            Follow the training principles in the README. Don’t upload anything to Garmin. At the end, briefly \
            summarize what you changed and why.
            """)
        case .block:
            return String(localized: """
            \(blockBrief(request, snapshot))

            Write the draft to plan-entwurf.json — same schema as plan.json (README, section “Plan schema”) with a “workout” \
            for every session, a new idPrefix (e.g. “b3”), a new workoutPrefix, fitting title/goal/subtitle, paceBands and athlete; \
            previous = a short look back at the current block. Do NOT change plan.json — the current block keeps running, the draft is \
            applied in the app. First review analysis.json (runs, ratings, week summaries) and the training principles in the \
            README. At the end, briefly explain the structure (phases, progression, pace bands) and what you deliberately do differently from the \
            current block.
            """)
        }
    }

    // MARK: Reine Text-CLIs

    static func textPrompt(for request: PlanRequest, snapshot: TrainingSnapshot, folder: URL) -> String {
        switch request.kind {
        case .week, .session:
            let week = request.kind == .session
                ? (request.sessionID.flatMap(snapshot.session(id:))?.week ?? request.week) : request.week
            let json = weekJSON(week, folder: folder) ?? "{}"
            return String(localized: """
            \(task(request, snapshot))

            You can’t change any files. Answer with a short rationale and then the complete new week \(week) \
            as JSON in a code block (```json … ```), in the same schema as below: phase, note, sessions with type, dist, desc and \
            workout. The app shows the suggestion and only applies it after you confirm.

            # Week \(week) so far (from plan.json)
            ```json
            \(json)
            ```

            \(schema)
            """)
        case .block:
            let plan = (try? String(contentsOf: folder.appending(path: TrainingFiles.plan), encoding: .utf8)) ?? "{}"
            return String(localized: """
            \(blockBrief(request, snapshot))

            You can’t change any files. Answer with a short explanation of the structure and then the complete new plan \
            as JSON in a code block (```json … ```), in the schema of the current plan below — with a new idPrefix (e.g. “b3”) and \
            workoutPrefix. The app saves it as a draft; it is applied in the app.

            # Current plan (plan.json)
            ```json
            \(plan)
            ```

            \(schema)
            """)
        }
    }

    static let schema = String(localized: """
    # Schema of a workout
    "workout": { "name": "6x800m", "steps": [ { "type": "warmup", "time": 600, "note": "…" }, \
    { "repeat": 6, "steps": [ { "type": "interval", "distance": 800, "pace": "4:45-5:15", "note": "…" }, \
    { "type": "recovery", "time": 90 } ] }, { "type": "cooldown", "time": 600 } ] }
    type: warmup, cooldown, interval, recovery or run. End: "distance" (metres) or "time" (seconds). \
    "pace" = name of a paceBand or "m:ss-m:ss"; without pace = free, by feel. Easy runs and long runs have no pace target.
    """)

    // MARK: Bausteine

    private static func task(_ request: PlanRequest, _ snapshot: TrainingSnapshot) -> String {
        let wish = request.details.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.kind {
        case .week:
            let week = min(max(request.week, 1), snapshot.weekCount)
            let sessions = snapshot.sessions(inWeek: week).map { session in
                "- \(session.kind.label) \(session.dist): \(session.desc)" + (snapshot.isDone(session) ? String(localized: " (already done)") : "")
            }
            let reason = wish.isEmpty ? String(localized: "none given — check from the latest runs and reviews whether the week works as planned") : wish
            return String(localized: """
            Re-plan week \(week) (\(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))), \(snapshot.phase(ofWeek: week))).
            Reason: \(reason)

            Planned so far:
            \(sessions.joined(separator: "\n"))
            """)
        case .session:
            guard let session = request.sessionID.flatMap(snapshot.session(id:)) else {
                return String(localized: "Change a session in the plan: \(wish)")
            }
            let wishText = wish.isEmpty ? String(localized: "none given — suggest a sensible adjustment") : wish
            return String(localized: """
            Change the session week \(session.week) · \(session.kind.label) (\(session.dist): \(session.desc)), \
            planned for \(Fmt.range(snapshot.monday(ofWeek: session.week), snapshot.sunday(ofWeek: session.week))).
            Request: \(wishText)
            """)
        case .block:
            return blockBrief(request, snapshot)
        }
    }

    private static func blockBrief(_ request: PlanRequest, _ snapshot: TrainingSnapshot) -> String {
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let wish = request.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalText = goal.isEmpty ? String(localized: "open — suggest something suitable") : goal
        let raceText = request.hasRace ? Fmt.longDate(request.raceDate) : String(localized: "none")
        let wishText = wish.isEmpty ? String(localized: "nothing in particular") : wish
        let currentSubtitle = snapshot.plan.subtitle ?? String(localized: "\(snapshot.weekCount) weeks")
        return String(localized: """
        Plan a new training block as a draft. Requirements:
        - Goal: \(goalText)
        - Target race: \(raceText)
        - Start: \(Fmt.longDate(DateUtil.startOfWeek(request.start)))
        - Duration: \(request.weeks) weeks, \(request.runsPerWeek) runs per week
        - Special considerations: \(wishText)
        Current block for comparison: \(snapshot.plan.title) (\(currentSubtitle)).
        """)
    }

    /// Die Woche als JSON-Text, so wie sie in plan.json steht.
    static func weekJSON(_ week: Int, folder: URL) -> String? {
        guard let document = try? JSONDocument(contentsOf: folder.appending(path: TrainingFiles.plan), style: .compact(width: 120)),
              let weeks = document.root["weeks"]?.arrayValue, week >= 1, week <= weeks.count else { return nil }
        return weeks[week - 1].rendered(.compact(width: 120))
    }
}

// MARK: - Vorschläge reiner Text-CLIs

/// JSON-Vorschlag aus der Antwort einer Text-CLI: eine Woche oder ein ganzer Plan (als Entwurf).
struct PlanProposal: Codable, Hashable, Sendable {
    enum Scope: Codable, Hashable, Sendable {
        case week(Int)
        case draft
    }

    var scope: Scope
    /// Der JSON-Text des Vorschlags.
    var json: String
    /// Unterschiede zum aktuellen Stand, zum Anzeigen.
    var changes: [String]

    /// Sucht den letzten ```json-Block und prüft, ob er zum erwarteten Schema passt.
    static func extract(from answer: String, request: PlanRequest.Kind, week: Int, current: TrainingPlan) -> PlanProposal? {
        let blocks = answer.matches(of: /```(?:json)?\s*\n([\s\S]*?)```/).map { String($0.1) }
        for text in blocks.reversed() {
            guard let value = try? OrderedJSON.parse(text) else { continue }
            let data = Data(value.rendered(.python).utf8)
            switch request {
            case .week, .session:
                guard let newWeek = try? JSONDecoder.snakeCase.decode(PlanWeek.self, from: data),
                      week >= 1, week <= current.weeks.count else { continue }
                var plan = current
                plan.weeks[week - 1] = newWeek
                return PlanProposal(scope: .week(week), json: value.rendered(.compact(width: 120)),
                                    changes: PlanDiff.changes(from: current, to: plan))
            case .block:
                guard let plan = try? PlanFiles.decode(data) else { continue }
                return PlanProposal(scope: .draft, json: value.rendered(.compact(width: 120)),
                                    changes: [String(localized: "Draft: \(plan.title) · \(plan.weeks.count) weeks starting \(DateUtil.day(fromISO: plan.startMonday).map(Fmt.dayMonth) ?? plan.startMonday)")])
            }
        }
        return nil
    }

    /// Übernimmt den Vorschlag in die Dateien (Woche in plan.json bzw. plan-entwurf.json).
    func apply(in folder: ProjectFolder) throws -> [String] {
        let value = try OrderedJSON.parse(json)
        switch scope {
        case .week(let week):
            let url = folder.file(TrainingFiles.plan)
            var document = try JSONDocument(contentsOf: url, style: .compact(width: 120))
            guard var weeks = document.root["weeks"]?.arrayValue, week >= 1, week <= weeks.count else {
                throw StoreError.missingFile(String(localized: "Week \(week) in plan.json"))
            }
            weeks[week - 1] = value
            document.root["weeks"] = .array(weeks)
            _ = try PlanFiles.decode(Data(document.text.utf8))   // nur gültige Pläne schreiben
            try document.write(to: url)
            return [TrainingFiles.plan]
        case .draft:
            let document = JSONDocument(root: value, style: .compact(width: 120))
            _ = try PlanFiles.decode(Data(document.text.utf8))
            try document.write(to: folder.file(PlanFiles.draft))
            return [PlanFiles.draft]
        }
    }
}
