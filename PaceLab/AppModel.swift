import SwiftUI
import WidgetKit

enum SidebarItem: Hashable {
    case overview, plan, runs, coach, history
}

/// Kurze Rückmeldung oben im Fenster (z. B. nach „Läufe laden“).
struct Toast: Identifiable, Equatable {
    enum Action: Equatable {
        case showRuns, showPlan, showHistory
    }

    let id = UUID()
    let message: String
    var symbol = "checkmark.circle.fill"
    var isError = false
    var action: Action?
}

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: TrainingSnapshot?
    private(set) var loadError: String?
    private(set) var lastLoaded: Date?
    /// Entwurf für einen neuen Block (plan-entwurf.json), falls vorhanden.
    private(set) var draft: TrainingPlan?
    private(set) var draftError: String?

    var section: SidebarItem? = .overview
    var selectedRunID: Run.ID?
    var selectedSessionID: PlannedSession.ID?
    var showSessionInspector = true
    /// Plan-Ansicht: aktueller Block oder Entwurf.
    var showDraft = false
    /// Offene Planungsanfrage (Formular).
    var planRequest: PlanRequest?
    /// Woche, die gerade auf Garmin angelegt werden soll (Bestätigung).
    var garminUploadWeek: Int?
    var toast: Toast?
    /// Zählt hoch, wenn ein neuer Stand festgehalten wurde (Verlauf lädt dann neu).
    private(set) var historyRevision = 0

    let coach = CoachModel()
    let sync = RunSyncModel()
    /// Welche Modelle die hinterlegten CLIs anbieten (live abgefragt).
    let models = ModelStore()
    private(set) var history: ProjectHistory

    private var signature: [String] = []
    private var isReloading = false
    private var reloadAgain = false

    init() {
        history = ProjectHistory(folder: ProjectFolder.current.url)
        coach.history = history
        coach.onRunFinished = { [weak self] in
            self?.historyRevision += 1
            self?.reload(force: true)
        }
        coach.snapshotProvider = { [weak self] in self?.snapshot }
        reload(force: true)
        watchFolder()
        // Was seit dem letzten Start außerhalb der App geändert wurde, als eigenen Stand festhalten.
        record(ProjectHistory.externalChanges)
        refreshModels()
    }

    /// Modelllisten der CLIs prüfen — neu abgefragt wird nur, wenn sich eine CLI-Version geändert hat.
    func refreshModels(force: Bool = false) {
        let engines = coach.engines
        let folder = self.folder.url
        Task {
            for engine in engines { await models.refresh(engine, folder: folder, force: force) }
        }
    }

    /// Die Claude-Code-Engine (auch für den Strava-Abruf).
    var claudeEngine: CoachEngine {
        coach.engines.first { $0.kind == .claudeCode } ?? .claudePreset()
    }

    var folder: ProjectFolder { .current }

    /// Programm der Claude-Code-Engine (auch für den Strava-Abruf).
    var claudeCommand: String { claudeEngine.command }

    // MARK: - Daten

    private struct DraftState: Sendable {
        var plan: TrainingPlan?
        var error: String?
    }

    private enum ReloadOutcome: Sendable {
        case unchanged
        case loaded([String], TrainingSnapshot, DraftState)
        case failed([String], String, DraftState)
    }

    /// Liest die JSON-Dateien neu, wenn sich etwas geändert hat, und gibt sie an die Widgets weiter.
    /// Die Datei-Zugriffe laufen im Hintergrund (beim ersten Start fragt macOS evtl. nach dem Dokumente-Ordner).
    func reload(force: Bool = false) {
        guard !isReloading else {
            reloadAgain = reloadAgain || force
            return
        }
        isReloading = true
        let folder = self.folder
        let previous = force ? nil : signature

        Task {
            let outcome = await Task.detached(priority: .utility) { () -> ReloadOutcome in
                let current = folder.signature()
                if let previous, previous == current { return .unchanged }
                var draft = DraftState()
                if let data = try? Data(contentsOf: folder.file(PlanFiles.draft)) {
                    do { draft.plan = try PlanFiles.decode(data) } catch {
                        draft.error = String(localized: "\(PlanFiles.draft) is invalid: \(error.localizedDescription)")
                    }
                }
                do {
                    let files = try folder.readFiles()
                    let snapshot = try TrainingFiles.decode(
                        plan: files[TrainingFiles.plan]!,
                        analysis: files[TrainingFiles.analysis]!,
                        completed: files[TrainingFiles.completed])
                    try? SnapshotStore.save(files)
                    return .loaded(current, snapshot, draft)
                } catch {
                    return .failed(current, error.localizedDescription, draft)
                }
            }.value

            switch outcome {
            case .unchanged:
                break
            case .loaded(let current, let snapshot, let draft):
                signature = current
                self.snapshot = snapshot
                loadError = nil
                lastLoaded = .now
                apply(draft)
                WidgetCenter.shared.reloadAllTimelines()
            case .failed(let current, let message, let draft):
                // Den letzten guten Stand behalten (z. B. während Claude eine Datei gerade umschreibt).
                signature = current
                loadError = message
                apply(draft)
            }
            isReloading = false
            if reloadAgain {
                reloadAgain = false
                reload(force: true)
            }
        }
    }

    private func apply(_ state: DraftState) {
        draft = state.plan
        draftError = state.error
        if draft == nil && state.error == nil { showDraft = false }
    }

    /// Schaut alle 2 Sekunden auf die Änderungszeiten — robust auch gegen atomares Ersetzen der Dateien.
    private func watchFolder() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.reload()
            }
        }
    }

    func folderChanged() {
        snapshot = nil
        draft = nil
        history = ProjectHistory(folder: folder.url)
        coach.history = history
        historyRevision += 1
        reload(force: true)
    }

    // MARK: - Versionsverwaltung

    /// Hält Änderungen als Stand fest (im Hintergrund; ohne Repository passiert nichts).
    func record(_ message: String, paths: [String]? = nil) {
        let history = self.history
        Task {
            if (try? await history.commit(message, paths: paths)) != nil {
                historyRevision += 1
            }
        }
    }

    func setUpHistory() async throws {
        try await history.setUp()
        historyRevision += 1
    }

    /// Löscht den Verlauf ganz (`days == nil`) oder die Stände, die älter als `days` Tage sind.
    /// Die Dateien bleiben unverändert; Verweise in Coach-Gesprächen werden umgeschrieben.
    func deleteHistory(olderThan days: Int?) async {
        let cutoff = days.map { Date.now.addingTimeInterval(-Double($0) * 86_400) }
        do {
            let result = try await history.deleteHistory(before: cutoff)
            coach.remapCommits(result.mapping)
            historyRevision += 1
            toast = result.removed == 0
                ? Toast(message: days == nil ? String(localized: "There is only the current version — nothing to delete.") : String(localized: "No versions older than \(days!) days."),
                        symbol: "checkmark.circle")
                : Toast(message: String(localized: "\(result.removed) versions deleted") + (result.kept > 0 ? String(localized: ", \(result.kept) kept") : ""),
                        symbol: "trash.circle.fill")
        } catch {
            toast = Toast(message: String(localized: "History not deleted: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    /// Nimmt die Änderungen eines Coach-Laufs zurück. Überschneiden sie sich mit späteren Änderungen,
    /// wird nachgefragt, ob die Dateien auf den Stand vor dem Lauf gesetzt werden sollen.
    func undo(_ turn: CoachTurn, force: Bool = false) async -> ProjectHistory.RevertOutcome? {
        guard let commit = turn.commit else { return nil }
        let message = String(localized: "Undone: \(turn.title ?? String(turn.prompt.prefix(60)))")
        do {
            if force, let base = turn.baseCommit {
                let files = turn.changedFiles ?? []
                if let restored = try await history.restore(files, to: base, message: message) {
                    coach.markReverted(turn: turn.id, commit: restored)
                }
                finishUndo()
                return .reverted(commit)
            }
            let outcome = try await history.revert(commit, message: message)
            if case .reverted(let hash) = outcome {
                coach.markReverted(turn: turn.id, commit: hash)
                finishUndo()
            }
            return outcome
        } catch {
            toast = Toast(message: String(localized: "Undo failed: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
            return nil
        }
    }

    /// Nimmt einen beliebigen Stand aus dem Verlauf zurück.
    func revert(_ entry: ProjectHistory.Entry) async -> ProjectHistory.RevertOutcome? {
        do {
            let outcome = try await history.revert(entry.id, message: String(localized: "Undone: \(entry.subject)"))
            if case .reverted = outcome { finishUndo() }
            return outcome
        } catch {
            toast = Toast(message: String(localized: "Undo failed: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
            return nil
        }
    }

    private func finishUndo() {
        historyRevision += 1
        reload(force: true)
        toast = Toast(message: String(localized: "Changes undone"), symbol: "arrow.uturn.backward.circle.fill", action: .showHistory)
    }

    // MARK: - Häkchen & Zuordnung

    func toggleDone(_ session: PlannedSession) {
        guard let snapshot else { return }
        let done = !snapshot.isDone(session)
        do {
            try folder.setCompleted(done, sessionID: session.id)
            let verb = done ? String(localized: "Checked off") : String(localized: "Unchecked")
            record("\(verb): W\(session.week) · \(session.kind.label) \(session.dist)",
                   paths: [TrainingFiles.completed])
            reload(force: true)
        } catch {
            loadError = String(localized: "completed.json could not be written: \(error.localizedDescription)")
        }
    }

    /// Ordnet einen Lauf einer Plan-Einheit zu und hakt sie mit dem Datum des Laufs ab (nil = Zuordnung lösen).
    func assign(_ run: Run, to session: PlannedSession?) {
        guard let snapshot, let day = run.day else { return }
        let runDay = DateUtil.germanDay(day)
        do {
            try AnalysisWriter.assign(runID: run.id, to: session?.id, in: folder)
            // Häkchen der bisherigen Einheit nur entfernen, wenn es von diesem Lauf stammt.
            if let old = run.sessionId.flatMap(snapshot.session(id:)), old.id != session?.id, snapshot.doneDate(old) == runDay {
                try folder.setCompleted(false, sessionID: old.id)
            }
            if let session, !snapshot.isDone(session) {
                try folder.setCompleted(true, sessionID: session.id, on: day)
            }
            let target = session.map { "W\($0.week) · \($0.kind.label)" } ?? String(localized: "no session")
            record(String(localized: "Assigned: \(Fmt.dayMonth(day)) \(run.name) → \(target)"),
                   paths: [TrainingFiles.analysis, TrainingFiles.completed])
            reload(force: true)
        } catch {
            toast = Toast(message: String(localized: "Assignment failed: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    // MARK: - Läufe laden

    func syncRuns() {
        guard let snapshot, !sync.isRunning else { return }
        guard !coach.isRunning else {
            toast = Toast(message: String(localized: "The coach is working right now — load runs afterwards."), symbol: "hourglass", isError: true)
            return
        }
        sync.start(folder: folder, snapshot: snapshot, history: history, claudeCommand: claudeCommand) { [weak self] changed in
            guard let self else { return }
            if changed {
                historyRevision += 1
                reload(force: true)
            }
            switch sync.state {
            case .finished(let summary):
                toast = Toast(message: summary.message,
                              symbol: summary.runIDs.isEmpty ? "checkmark.circle" : "figure.run.circle.fill",
                              action: summary.runIDs.isEmpty ? nil : .showRuns)
                if let first = summary.runIDs.first { selectedRunID = first }
            case .failed(let message):
                toast = Toast(message: message, symbol: "exclamationmark.triangle.fill", isError: true)
            default:
                break
            }
        }
    }

    // MARK: - Planen

    /// Öffnet das Formular für eine Planungsanfrage.
    func requestPlan(_ kind: PlanRequest.Kind, week: Int? = nil, session: PlannedSession? = nil) {
        planRequest = PlanRequest(kind: kind, snapshot: snapshot, week: session?.week ?? week, sessionID: session?.id)
    }

    func submit(_ request: PlanRequest) {
        planRequest = nil
        guard let snapshot, !coach.isRunning, !sync.isRunning else { return }
        section = .coach
        coach.plan(request, snapshot: snapshot, in: folder.url)
    }

    /// Übernimmt den Vorschlag einer Text-CLI (Woche in plan.json bzw. Entwurf).
    func apply(_ proposal: PlanProposal, from turn: CoachTurn) {
        do {
            let paths = try proposal.apply(in: folder)
            coach.markProposalApplied(turn: turn.id)
            record(String(localized: "Suggestion applied: \(turn.title ?? "Plan")"), paths: paths)
            reload(force: true)
            if case .draft = proposal.scope { showDraft = true }
            section = .plan
        } catch {
            toast = Toast(message: String(localized: "Suggestion not applied: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    /// Entwurf wird aktiver Plan; der bisherige Plan wandert nach plans/.
    func applyDraft() {
        do {
            let planURL = folder.file(TrainingFiles.plan)
            let draftURL = folder.file(PlanFiles.draft)
            let current = try Data(contentsOf: planURL)
            let proposed = try Data(contentsOf: draftURL)
            let currentPlan = try PlanFiles.decode(current)
            let newPlan = try PlanFiles.decode(proposed)
            guard newPlan.idPrefix != currentPlan.idPrefix else {
                toast = Toast(message: String(localized: "The draft uses the same idPrefix as the current block — please have the coach assign a new one."),
                              symbol: "exclamationmark.triangle.fill", isError: true)
                return
            }
            let archive = folder.url.appending(path: PlanFiles.archive, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let archiveName = "\(currentPlan.startMonday)-\(currentPlan.idPrefix ?? "plan").json"
            let archived = archive.appending(path: archiveName)
            if !FileManager.default.fileExists(atPath: archived.path) {
                try current.write(to: archived, options: .atomic)
            }
            try proposed.write(to: planURL, options: .atomic)
            try FileManager.default.removeItem(at: draftURL)
            record(String(localized: "New block: \(newPlan.title)\n\nThe previous plan “\(currentPlan.title)” is now in \(PlanFiles.archive)/\(archiveName)."),
                   paths: [TrainingFiles.plan, PlanFiles.draft, "\(PlanFiles.archive)/\(archiveName)"])
            showDraft = false
            reload(force: true)
            toast = Toast(message: String(localized: "“\(newPlan.title)” is now the active plan"), symbol: "calendar.badge.checkmark", action: .showPlan)
        } catch {
            toast = Toast(message: String(localized: "Draft not applied: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    func discardDraft() {
        let title = draft?.title ?? String(localized: "Draft")
        do {
            try FileManager.default.removeItem(at: folder.file(PlanFiles.draft))
            record(String(localized: "Draft discarded: \(title)"), paths: [PlanFiles.draft])
            showDraft = false
            reload(force: true)
        } catch {
            toast = Toast(message: String(localized: "Draft not deleted: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    // MARK: - Navigation

    func show(_ run: Run) {
        selectedRunID = run.id
        section = .runs
    }

    func show(_ session: PlannedSession) {
        selectedSessionID = session.id
        showSessionInspector = true
        showDraft = false
        section = .plan
    }

    func perform(_ action: Toast.Action) {
        toast = nil
        switch action {
        case .showRuns: section = .runs
        case .showPlan: showDraft = false; section = .plan
        case .showHistory: section = .history
        }
    }

    func startCoach(_ action: CoachAction) {
        guard !sync.isRunning else {
            toast = Toast(message: String(localized: "Runs are being loaded right now — try again in a moment."), symbol: "hourglass", isError: true)
            return
        }
        section = .coach
        coach.run(action, in: folder.url)
    }

    func askCoach(about run: Run) {
        guard !coach.isRunning else { section = .coach; return }
        coach.newConversation()
        let day = run.day.map(Fmt.weekdayDayMonth) ?? run.date
        coach.draft = run.isAnalyzed
            ? String(localized: "About my run “\(run.name)” from \(day): ")
            : String(localized: "Review my run “\(run.name)” from \(day) (add an entry to analysis.json, assign the session and tick it off). ")
        section = .coach
    }

    /// Deep Links aus den Widgets: `pacelab://session/<id>`, `run/<id>`, `plan`, `runs`, `coach`.
    func open(_ url: URL) {
        guard url.scheme == "pacelab" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host() {
        case "session":
            if let session = snapshot?.session(id: id) { show(session) } else { section = .plan }
        case "run":
            if let run = snapshot?.run(id: id) { show(run) } else { section = .runs }
        case "plan": section = .plan
        case "runs": section = .runs
        case "coach": section = .coach
        default: section = .overview
        }
    }
}
