import Foundation

/// Anweisungen und Trainingsstand für die Coach-Engines.
enum CoachContext {
    /// Zeile, mit der ein Agent signalisiert, dass als Nächstes ein Garmin-Upload anstünde.
    static let uploadMarker = "[[GARMIN-FREIGABE]]"

    static let uploadRelease = "\n\n[Garmin-Freigabe: In dieser Nachricht darfst du Garmin-Workouts anlegen, einplanen oder löschen.]"

    // MARK: Wer trainiert

    /// Name aus den Einstellungen — die Anweisungen bleiben ohne Namen neutral.
    private static var person: (name: String, subject: String, object: String) {
        let name = AppSettings.athleteName
        return name.isEmpty ? ("", "Die Person, die trainiert,", "die Person, die trainiert") : (name, name, name)
    }

    // MARK: Agenten (Claude Code, Codex)

    static func agentInstructions(for kind: CoachEngine.Kind) -> String {
        let memory = kind == .claudeCode
            ? " Berücksichtige außerdem dein Gedächtnis (Memory)."
            : " Strava steht dir nicht zur Verfügung — hol Läufe immer direkt über Garmin (list_activities, get_activity_data), auch wo README oder Anfrage Strava nennen."
        let p = person
        let coachOf = p.name.isEmpty ? "ein persönlicher Lauf-Coach" : "der persönliche Lauf-Coach von \(p.name)"
        return """
        Du bist \(coachOf) und arbeitest in der Mac-App „Pace Lab“. Das Arbeitsverzeichnis ist der Trainingsordner.
        - Lies zu Beginn eines Gesprächs README.md vollständig: Sie beschreibt Athletenprofil, Plan, Regeln und den Ablauf einer Wochenauswertung.\(memory)
        - \(p.subject) liest deine Antworten in der App, nicht im Terminal: Schreib alles auf Deutsch — auch kurze Zwischenbemerkungen —, klar und kompakt, mit einfachem Markdown (kurze Absätze, Listen, höchstens kleine Tabellen). Keine Diffs oder JSON-Auszüge, außer danach wird gefragt.
        - Während du arbeitest, kannst du nicht nachfragen. Fehlt dir eine Entscheidung, arbeite so weit wie sinnvoll und stelle die Frage am Ende deiner Antwort.
        - Gib keine medizinischen Ratschläge (keine Medikamenten- oder Dosierungstipps); verweise dafür auf Ärztin oder Arzt. Gesundheitliche Hinweise aus dem Athletenprofil nutzt du nur zur Einordnung der Daten.
        - Garmin-Workouts anlegen, einplanen oder löschen darfst du nur, wenn die Nachricht eine ausdrückliche Garmin-Freigabe enthält — ohne Freigabe stehen dir diese Werkzeuge gar nicht zur Verfügung. Wäre ein Garmin-Upload der nächste sinnvolle Schritt, beende deine Antwort mit einer eigenen letzten Zeile, die genau so lautet: \(uploadMarker) — die App zeigt dann einen Knopf zum Freigeben.
        - Die App zeigt plan.json, analysis.json und completed.json live an: Halte dich exakt an die Schemata aus README.md und schreibe immer gültiges JSON.
        - Der Plan steht nur in plan.json — samt „workout“ je Einheit, aus dem der Garmin-Server die Workouts baut. Einen neuen Block schreibst du als Entwurf nach plan-entwurf.json; übernommen wird er in der App.
        - Einträge in analysis.json mit „source“ und ohne „verdict“ hat die App schon von Strava/Garmin geladen: Bei der Auswertung ergänzt du genau diese Einträge (IDs und Messwerte behalten, Splits bei Bedarf genauer benennen) und legst keine doppelten an.
        - Die App hält vor und nach deinem Lauf automatisch einen Stand fest (git) und kann ihn rückgängig machen. Führe selbst keine git-Befehle aus.
        """
    }

    // MARK: Reine Text-CLIs (z. B. lokale Modelle)

    static var textInstructions: String {
        let p = person
        let coachOf = p.name.isEmpty ? "ein persönlicher Lauf-Coach" : "der persönliche Lauf-Coach von \(p.name)"
        return """
        Du bist \(coachOf) in der Mac-App „Pace Lab“. Du hast keinen Zugriff auf Dateien, Strava oder Garmin — nutze nur den Trainingsstand, das Athletenprofil und das bisherige Gespräch, die dir mitgeschickt werden. Antworte auf Deutsch, klar und kompakt, mit einfachem Markdown.
        Halte dich an die Regeln aus dem Athletenprofil. Allgemein gilt: lockere Läufe wirklich locker, höchstens zwei fordernde Einheiten pro Woche; eine hohe Herzfrequenz erst mit Hitze, Anstiegen oder Tagesform erklären, bevor du die Fitness infrage stellst.
        Gib keine medizinischen Ratschläge (keine Medikamenten- oder Dosierungstipps) und verweise dafür auf Ärztin oder Arzt.
        \(readOnlyNote)
        """
    }

    private static let readOnlyNote = "Du kannst nichts ändern. Soll etwas am Plan oder an den Daten geändert werden, weise darauf hin, dass dafür Claude Code oder Codex als Engine nötig ist."

    /// Für Planungsanfragen an reine Text-CLIs: gleiche Regeln, aber Antwort mit JSON-Vorschlag.
    static var textPlanningInstructions: String {
        textInstructions.replacingOccurrences(
            of: readOnlyNote,
            with: "Du kannst keine Dateien ändern, aber einen Plan-Vorschlag als JSON machen, den die App nach Bestätigung übernimmt. Halte dich genau an das verlangte Schema und schreibe gültiges JSON.")
    }

    /// Abschnitt „## Athletenprofil“ aus der README des Trainingsordners (für Engines ohne Dateizugriff).
    static func athleteProfile(folder: URL) -> String? {
        guard let readme = try? String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8),
              let start = readme.range(of: "\n## Athletenprofil") ?? (readme.hasPrefix("## Athletenprofil") ? readme.range(of: "## Athletenprofil") : nil)
        else { return nil }
        let rest = readme[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        let body = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "# Athletenprofil\n" + body
    }

    /// Trainingsstand als Text — kompakt genug auch für lokale Modelle mit kleinem Kontext.
    static func training(_ snapshot: TrainingSnapshot?, level: CoachEngine.ContextLevel, folder: URL,
                         today: Date = .now) -> String {
        guard level != .none, let s = snapshot else { return "" }
        var lines = ["# Trainingsstand (Stand: \(Fmt.longDate(today)))"]
        lines.append("Block: \(s.plan.title)" + (s.plan.goal.map { " — Ziel: \($0)" } ?? "")
                     + (s.plan.subtitle.map { " (\($0))" } ?? ""))
        lines.append("Status: \(s.statusLine(on: today)), \(s.doneCount) von \(s.sessions.count) Einheiten erledigt")

        let focus = s.focusWeek(on: today)
        for week in [focus, focus + 1] where week <= s.weekCount {
            let sessions = s.sessions(inWeek: week)
            let done = sessions.filter(s.isDone).count
            lines.append("")
            lines.append("## Woche \(week) (\(Fmt.range(s.monday(ofWeek: week), s.sunday(ofWeek: week))), \(s.phase(ofWeek: week))"
                         + (s.note(ofWeek: week).map { ", \($0)" } ?? "")
                         + "): \(done)/\(sessions.count) erledigt, \(Fmt.km(s.actualKm(week: week))) von \(Fmt.km(s.plannedKm(week: week), digits: 0)) km")
            for session in sessions {
                let mark = s.isDone(session) ? "[x]" : "[ ]"
                let date = s.doneDate(session).map { " (erledigt \($0))" } ?? ""
                lines.append("- \(mark) \(session.kind.label) \(session.dist): \(session.desc)\(date)")
            }
        }

        if let next = s.nextSession {
            lines.append("")
            lines.append("Nächste Einheit: Woche \(next.week), \(next.kind.label) \(next.dist) — \(next.desc)")
        }
        if let bands = s.plan.paceBands, !bands.isEmpty {
            lines.append("Pace-Bänder: " + bands.map { "\($0.name) \($0.range)/km" + ($0.note.map { " (\($0))" } ?? "") }
                .joined(separator: "; "))
        }
        lines.append("HF-Zonen" + (s.plan.athlete.map { " (HFmax \($0.maxHr))" } ?? "") + ": "
                     + s.zoneLegend.map { "Z\($0.zone) \($0.range)" }.joined(separator: " · "))

        lines.append("")
        lines.append("## Letzte Läufe")
        for run in s.runs.prefix(5) {
            var line = "- \(run.day.map(Fmt.weekdayDayMonth) ?? run.date) \(run.name)"
            if let label = s.label(for: run) ?? run.tag { line += " [\(label)]" }
            line += ": \(Fmt.km(run.distanceKm, digits: 2)) km, \(Fmt.pace(run.paceSeconds))/km"
            if let hr = run.avgHr { line += ", Ø HF \(Fmt.int(hr))" }
            if let max = run.maxHr { line += ", max \(Fmt.int(max))" }
            if let verdict = run.verdict { line += ", Bewertung: \(verdict.label)" }
            if let flags = run.flags, !flags.isEmpty { line += ". Hinweise: \(flags.joined(separator: "; "))" }
            if let analysis = run.analysis { line += ". Analyse: \(shorten(analysis, to: 320))" }
            lines.append(line)
        }
        if let summary = s.weekSummaries.max(by: { $0.week < $1.week }), let text = summary.analysis {
            lines.append("")
            lines.append("Letztes Wochenfazit (Woche \(summary.week)): \(shorten(text, to: 500))")
        }

        if level == .full, let readme = try? String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8) {
            lines.append("")
            lines.append("# README.md (Regeln und Hintergrund)")
            lines.append(readme)
        }
        return lines.joined(separator: "\n")
    }

    /// Bisheriges Gespräch für Engines ohne eigene Sessions.
    static func history(_ turns: [CoachTurn], limit: Int = 6) -> String {
        let recent = turns.filter { $0.state == .done }.suffix(limit)
        guard !recent.isEmpty else { return "" }
        var lines = ["# Bisheriges Gespräch"]
        for turn in recent {
            lines.append("\(AppSettings.athleteName.isEmpty ? "Nutzer" : AppSettings.athleteName): \(shorten(turn.prompt, to: 600))")
            let answer = turn.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            if !answer.isEmpty { lines.append("Coach: \(shorten(answer, to: 1_200))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Denk-Abschnitte lokaler Modelle (`<think>…</think>`) aus der Antwort entfernen.
    static func removeThinking(_ text: String) -> String {
        text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shorten(_ text: String, to length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }
}
