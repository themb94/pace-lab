import Foundation

/// Eine Planungsanfrage an den Coach — Woche umbauen, Einheit ändern oder neuen Block entwerfen.
struct PlanRequest: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable, Codable, Sendable {
        case week, session, block

        var id: String { rawValue }

        var label: String {
            switch self {
            case .week: "Woche anpassen"
            case .session: "Einheit ändern"
            case .block: "Neuen Block planen"
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
        case .week: return "Woche \(request.week) anpassen"
        case .session:
            guard let session = request.sessionID.flatMap(snapshot.session(id:)) else { return "Einheit ändern" }
            return "W\(session.week) · \(session.kind.label) ändern"
        case .block: return "Neuen Block planen"
        }
    }

    // MARK: Agenten (Claude Code, Codex)

    static func agentPrompt(for request: PlanRequest, snapshot: TrainingSnapshot) -> String {
        switch request.kind {
        case .week, .session:
            return """
            \(task(request, snapshot))

            Ändere dafür plan.json direkt: die betroffenen Einheiten (type, dist, desc) und passend dazu jeweils das „workout“ \
            (Schema: README, Abschnitt „Plan-Schema“ — garmin_workouts.py baut daraus die Garmin-Workouts, dort also nichts ändern). \
            Andere Wochen nur anpassen, wenn es wegen dieser Änderung wirklich nötig ist, und das dann begründen. Die Häkchen hängen an \
            Typ und Position der Einheit ({idPrefix}w{Woche}-{type}-{index}) — bei schon abgehakten Einheiten Typ und Reihenfolge also \
            nicht ändern. Halte dich an die Trainingsprinzipien der README. Lade nichts auf Garmin hoch. Fasse zum Schluss knapp \
            zusammen, was du geändert hast und warum.
            """
        case .block:
            return """
            \(blockBrief(request, snapshot))

            Schreib den Entwurf nach plan-entwurf.json — gleiches Schema wie plan.json (README, Abschnitt „Plan-Schema“) mit „workout“ \
            für jede Einheit, neuem idPrefix (z. B. „b3“), neuem workoutPrefix, passendem title/goal/subtitle, paceBands und athlete; \
            previous = kurzer Rückblick auf den aktuellen Block. plan.json NICHT ändern — der aktuelle Block läuft weiter, der Entwurf wird \
            in der App übernommen. Werte vorher analysis.json (Läufe, Bewertungen, Wochenfazits) und die Trainingsprinzipien der \
            README aus. Erkläre zum Schluss kurz den Aufbau (Phasen, Progression, Pace-Bänder) und was du bewusst anders machst als im \
            aktuellen Block.
            """
        }
    }

    // MARK: Reine Text-CLIs

    static func textPrompt(for request: PlanRequest, snapshot: TrainingSnapshot, folder: URL) -> String {
        switch request.kind {
        case .week, .session:
            let week = request.kind == .session
                ? (request.sessionID.flatMap(snapshot.session(id:))?.week ?? request.week) : request.week
            let json = weekJSON(week, folder: folder) ?? "{}"
            return """
            \(task(request, snapshot))

            Du kannst keine Dateien ändern. Antworte mit einer kurzen Begründung und danach mit der vollständigen neuen Woche \(week) \
            als JSON in einem Codeblock (```json … ```), im selben Schema wie unten: phase, note, sessions mit type, dist, desc und \
            workout. Die App zeigt den Vorschlag und übernimmt ihn erst nach Bestätigung.

            # Woche \(week) bisher (aus plan.json)
            ```json
            \(json)
            ```

            \(schema)
            """
        case .block:
            let plan = (try? String(contentsOf: folder.appending(path: TrainingFiles.plan), encoding: .utf8)) ?? "{}"
            return """
            \(blockBrief(request, snapshot))

            Du kannst keine Dateien ändern. Antworte mit einer kurzen Erklärung des Aufbaus und danach mit dem vollständigen neuen Plan \
            als JSON in einem Codeblock (```json … ```), im Schema des aktuellen Plans unten — mit neuem idPrefix (z. B. „b3“) und \
            workoutPrefix. Die App legt ihn als Entwurf ab; übernommen wird er in der App.

            # Aktueller Plan (plan.json)
            ```json
            \(plan)
            ```

            \(schema)
            """
        }
    }

    static let schema = """
    # Schema eines Workouts
    "workout": { "name": "6x800m", "steps": [ { "type": "warmup", "time": 600, "note": "…" }, \
    { "repeat": 6, "steps": [ { "type": "interval", "distance": 800, "pace": "4:45-5:15", "note": "…" }, \
    { "type": "recovery", "time": 90 } ] }, { "type": "cooldown", "time": 600 } ] }
    type: warmup, cooldown, interval, recovery oder run. Ende: "distance" (Meter) oder "time" (Sekunden). \
    "pace" = Name eines paceBands oder "m:ss-m:ss"; ohne pace = frei nach Gefühl. Locker-Läufe und Long Runs haben kein Pace-Ziel.
    """

    // MARK: Bausteine

    private static func task(_ request: PlanRequest, _ snapshot: TrainingSnapshot) -> String {
        let wish = request.details.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.kind {
        case .week:
            let week = min(max(request.week, 1), snapshot.weekCount)
            let sessions = snapshot.sessions(inWeek: week).map { session in
                "- \(session.kind.label) \(session.dist): \(session.desc)" + (snapshot.isDone(session) ? " (schon erledigt)" : "")
            }
            return """
            Plane Woche \(week) (\(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))), \(snapshot.phase(ofWeek: week))) um.
            Anlass: \(wish.isEmpty ? "keiner angegeben — prüfe anhand der letzten Läufe und Auswertungen, ob die Woche so passt" : wish)

            Bisher geplant:
            \(sessions.joined(separator: "\n"))
            """
        case .session:
            guard let session = request.sessionID.flatMap(snapshot.session(id:)) else {
                return "Ändere eine Einheit im Plan: \(wish)"
            }
            return """
            Ändere die Einheit Woche \(session.week) · \(session.kind.label) (\(session.dist): \(session.desc)), \
            geplant für \(Fmt.range(snapshot.monday(ofWeek: session.week), snapshot.sunday(ofWeek: session.week))).
            Wunsch: \(wish.isEmpty ? "keiner angegeben — schlag eine sinnvolle Anpassung vor" : wish)
            """
        case .block:
            return blockBrief(request, snapshot)
        }
    }

    private static func blockBrief(_ request: PlanRequest, _ snapshot: TrainingSnapshot) -> String {
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let wish = request.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Plane einen neuen Trainingsblock als Entwurf. Vorgaben:
        - Ziel: \(goal.isEmpty ? "offen — schlag etwas Passendes vor" : goal)
        - Zielrennen: \(request.hasRace ? Fmt.longDate(request.raceDate) : "keins")
        - Start: \(Fmt.longDate(DateUtil.startOfWeek(request.start)))
        - Dauer: \(request.weeks) Wochen, \(request.runsPerWeek) Läufe pro Woche
        - Besonderheiten: \(wish.isEmpty ? "keine" : wish)
        Aktueller Block zum Vergleich: \(snapshot.plan.title) (\(snapshot.plan.subtitle ?? "\(snapshot.weekCount) Wochen")).
        """
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
                                    changes: ["Entwurf: \(plan.title) · \(plan.weeks.count) Wochen ab \(DateUtil.day(fromISO: plan.startMonday).map(Fmt.dayMonth) ?? plan.startMonday)"])
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
                throw StoreError.missingFile("Woche \(week) in plan.json")
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
