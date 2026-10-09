import Foundation

/// Instructions and training state for the coach engines.
/// The texts go to the models and are therefore in English; the language the coach replies in
/// is determined by `replyLanguage` (the app's language).
enum CoachContext {
    /// Line with which an agent signals that a Garmin upload would be next.
    static let uploadMarker = "[[GARMIN-APPROVAL]]"

    /// Earlier versions wrote "[[GARMIN-FREIGABE]]" — both are recognized in older conversations.
    static let uploadMarkers = [uploadMarker, "[[GARMIN-FREIGABE]]"]

    static let uploadRelease = "\n\n[Garmin approval: In this message you may create, schedule or delete Garmin workouts.]"

    /// Language the coach replies in: the app's.
    static var replyLanguage: String { Locale(identifier: "en").localizedString(forLanguageCode: AppLanguage.code) ?? "English" }

    // MARK: Who is training

    /// Name from Settings — the instructions stay neutral without a name.
    private static var person: (name: String, subject: String) {
        let name = AppSettings.athleteName
        return name.isEmpty ? ("", "The person you coach") : (name, name)
    }

    // MARK: Agents (Claude Code, Codex)

    static func agentInstructions(for kind: CoachEngine.Kind, watch: WatchKind = .garmin) -> String {
        let memory = kind == .claudeCode
            ? " Also take your memory into account."
            : watch == .none
            ? " Strava isn’t available to you and no watch is connected — work with the runs that are already in analysis.json."
            : " Strava isn’t available to you — always fetch runs directly through \(watch.label) (list_activities, get_activity_data), even where the README or the request mention Strava."
        let p = person
        let coachOf = p.name.isEmpty ? "a personal running coach" : "the personal running coach of \(p.name)"
        return """
        You are \(coachOf) and work in the Mac app “Pace Lab”. The working directory is the training folder.
        - At the start of a conversation, read README.md in full: it describes the athlete profile, the plan, the rules and how a weekly review works.\(memory)
        - \(p.subject) reads your replies in the app, not in a terminal: write everything in \(replyLanguage) — even short remarks while you work —, clear and compact, with simple Markdown (short paragraphs, lists, small tables at most). No diffs or JSON excerpts unless asked.
        - While you work you can’t ask questions. If a decision is missing, work as far as makes sense and put the question at the end of your reply.
        - Give no medical advice (no medication or dosage tips); refer to a doctor for that. Use health notes from the athlete profile only to interpret the data.
        - \(watchRule(watch))
        - The app displays plan.json, analysis.json and completed.json live: follow the schemas in README.md exactly and always write valid JSON.
        - The plan lives only in plan.json — including a “workout” per session, from which the workouts for the watch are built. Write a new block as a draft to plan-entwurf.json; it is applied in the app.
        - Entries in analysis.json with “source” and without “verdict” were already loaded from Strava, Garmin or Polar by the app: during a review, complete exactly those entries (keep IDs and measurements, name splits more precisely if needed) and don’t create duplicates.
        - The app records a version (git) automatically before and after your run and can undo it. Don’t run git commands yourself.
        """
    }

    /// What the coach may do with the profile's watch.
    private static func watchRule(_ watch: WatchKind) -> String {
        switch watch {
        case .garmin:
            "You may only create, schedule or delete Garmin workouts if the message contains an explicit Garmin approval — without it these tools aren’t available to you at all. If a Garmin upload would be the next sensible step, end your reply with a last line of its own that reads exactly: \(uploadMarker) — the app then shows a button to approve."
        case .polar:
            "The athlete trains with a Polar watch: runs come from the server “polar” (list_activities, get_activity_data — laps are kilometer splits computed from the watch’s samples; preview_plan shows a week as Polar phases). Workouts can’t be sent to a Polar watch automatically: the app shows a week as phases to enter in Polar Flow (“Week for Polar”). Wherever the README mentions Garmin, take it to mean the Polar watch. Never write \(uploadMarker)."
        case .none:
            "No watch is connected: runs come from Strava or are entered by hand; nothing can be sent to a watch. Never write \(uploadMarker)."
        }
    }

    // MARK: Plain text CLIs (e.g. local models)

    static var textInstructions: String {
        let p = person
        let coachOf = p.name.isEmpty ? "a personal running coach" : "the personal running coach of \(p.name)"
        return """
        You are \(coachOf) in the Mac app “Pace Lab”. You have no access to files, Strava or Garmin — use only the training status, the athlete profile and the conversation so far that are sent to you. Answer in \(replyLanguage), clear and compact, with simple Markdown.
        Follow the rules in the athlete profile. In general: easy runs really easy, at most two demanding sessions per week; explain a high heart rate with heat, hills or form of the day before you question fitness.
        Give no medical advice (no medication or dosage tips) and refer to a doctor for that.
        \(readOnlyNote)
        """
    }

    private static let readOnlyNote = "You can’t change anything. If something in the plan or the data should change, point out that Claude Code or Codex is needed as the engine."

    /// For planning requests to plain text CLIs: the same rules, but the reply is a JSON suggestion.
    static var textPlanningInstructions: String {
        textInstructions.replacingOccurrences(
            of: readOnlyNote,
            with: "You can’t change files, but you can make a plan suggestion as JSON that the app applies after confirmation. Follow the requested schema exactly and write valid JSON.")
    }

    /// Section "## Athletenprofil" or "## Athlete profile" from the training folder's README (for engines without file access).
    static func athleteProfile(folder: URL) -> String? {
        guard let readme = try? String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8) else { return nil }
        for heading in ["## Athletenprofil", "## Athlete profile"] {
            guard let start = readme.range(of: "\n" + heading) ?? (readme.hasPrefix(heading) ? readme.range(of: heading) : nil) else { continue }
            let rest = readme[start.upperBound...]
            let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
            let body = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : "# Athlete profile\n" + body
        }
        return nil
    }

    /// Training state as text — compact enough even for local models with a small context.
    static func training(_ snapshot: TrainingSnapshot?, level: CoachEngine.ContextLevel, folder: URL,
                         today: Date = .now) -> String {
        guard level != .none, let s = snapshot else { return "" }
        var lines = ["# Training status (as of \(Fmt.longDate(today)))"]
        lines.append("Block: \(s.plan.title)" + (s.plan.goal.map { " — goal: \($0)" } ?? "")
                     + (s.plan.subtitle.map { " (\($0))" } ?? ""))
        lines.append("Status: \(s.statusLine(on: today)), \(s.doneCount) of \(s.sessions.count) sessions done")

        let focus = s.focusWeek(on: today)
        for week in [focus, focus + 1] where week <= s.weekCount {
            let sessions = s.sessions(inWeek: week)
            let done = sessions.filter(s.isDone).count
            lines.append("")
            lines.append("## Week \(week) (\(Fmt.range(s.monday(ofWeek: week), s.sunday(ofWeek: week))), \(s.phase(ofWeek: week))"
                         + (s.note(ofWeek: week).map { ", \($0)" } ?? "")
                         + "): \(done)/\(sessions.count) done, \(Fmt.km(s.actualKm(week: week))) of \(Fmt.km(s.plannedKm(week: week), digits: 0)) km")
            for session in sessions {
                let mark = s.isDone(session) ? "[x]" : "[ ]"
                let date = s.doneDate(session).map { " (done \($0))" } ?? ""
                lines.append("- \(mark) \(session.kind.label) \(session.dist): \(session.desc)\(date)")
            }
        }

        if let next = s.nextSession {
            lines.append("")
            lines.append("Next session: week \(next.week), \(next.kind.label) \(next.dist) — \(next.desc)")
        }
        if let bands = s.plan.paceBands, !bands.isEmpty {
            lines.append("Pace bands: " + bands.map { "\($0.name) \($0.range)/km" + ($0.note.map { " (\($0))" } ?? "") }
                .joined(separator: "; "))
        }
        lines.append("HR zones" + (s.plan.athlete.map { " (HRmax \($0.maxHr))" } ?? "") + ": "
                     + s.zoneLegend.map { "Z\($0.zone) \($0.range)" }.joined(separator: " · "))

        lines.append("")
        lines.append("## Latest runs")
        for run in s.runs.prefix(5) {
            var line = "- \(run.day.map(Fmt.weekdayDayMonth) ?? run.date) \(run.name)"
            if let label = s.label(for: run) ?? run.tag { line += " [\(label)]" }
            line += ": \(Fmt.km(run.distanceKm, digits: 2)) km, \(Fmt.pace(run.paceSeconds))/km"
            if let hr = run.avgHr { line += ", avg HR \(Fmt.int(hr))" }
            if let max = run.maxHr { line += ", max \(Fmt.int(max))" }
            if let verdict = run.verdict { line += ", rating: \(verdict.label)" }
            if let flags = run.flags, !flags.isEmpty { line += ". Notes: \(flags.joined(separator: "; "))" }
            if let analysis = run.analysis { line += ". Analysis: \(shorten(analysis, to: 320))" }
            lines.append(line)
        }
        if let summary = s.weekSummaries.max(by: { $0.week < $1.week }), let text = summary.analysis {
            lines.append("")
            lines.append("Latest week summary (week \(summary.week)): \(shorten(text, to: 500))")
        }

        if level == .full, let readme = try? String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8) {
            lines.append("")
            lines.append("# README.md (rules and background)")
            lines.append(readme)
        }
        return lines.joined(separator: "\n")
    }

    /// Previous conversation for engines without sessions of their own.
    static func history(_ turns: [CoachTurn], limit: Int = 6) -> String {
        let recent = turns.filter { $0.state == .done }.suffix(limit)
        guard !recent.isEmpty else { return "" }
        var lines = ["# Conversation so far"]
        for turn in recent {
            lines.append("\(AppSettings.athleteName.isEmpty ? "User" : AppSettings.athleteName): \(shorten(turn.prompt, to: 600))")
            let answer = turn.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            if !answer.isEmpty { lines.append("Coach: \(shorten(answer, to: 1_200))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Remove local models' thinking sections (`<think>…</think>`) from the reply.
    static func removeThinking(_ text: String) -> String {
        text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shorten(_ text: String, to length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }
}
