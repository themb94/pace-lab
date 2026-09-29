import AppKit
import Observation

/// Vorgefertigte Anfragen für die Wochenroutine: auswerten → vorbereiten → hochladen.
/// Brauchen einen Agenten (Claude Code oder Codex).
struct CoachAction: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let help: String
    let prompt: String
    let allowUpload: Bool
    /// Startet immer ein neues Gespräch (die Auswertung ist der Beginn des Wochenzyklus).
    let startsConversation: Bool
    /// Nur sinnvoll in einem laufenden Gespräch (z. B. Upload der gerade besprochenen Woche).
    let needsConversation: Bool

    static let reviewWeek = CoachAction(
        id: "review", title: "Woche auswerten", symbol: "chart.bar.doc.horizontal",
        help: "Läufe holen, abhaken und analysieren",
        prompt: """
        Mach die Wochenauswertung für die zuletzt gelaufene Trainingswoche, genau wie in README.md beschrieben: \
        Läufe holen (Strava bzw. Garmin, wie in der README festgelegt), completed.json und analysis.json aktualisieren und \
        ein Wochenfazit in weekSummaries schreiben. Läufe, die die App schon geladen hat (Einträge mit „source“ und \
        ohne „verdict“), ergänzt du, statt sie neu anzulegen. Lege keine Garmin-Workouts an. Antworte zum Schluss \
        mit einer kurzen Zusammenfassung: welche Läufe, deine Bewertung und deine Empfehlung für die nächste Woche.
        """,
        allowUpload: false, startsConversation: true, needsConversation: false)

    static let prepareWeek = CoachAction(
        id: "prepare", title: "Nächste Woche vorbereiten", symbol: "calendar.badge.plus",
        help: "Plan prüfen und anpassen, Vorschau zeigen — noch ohne Upload",
        prompt: """
        Bereite die nächste Trainingswoche vor: Berücksichtige die letzte Auswertung und alles, was ich dir zu \
        dieser Woche gesagt habe. Passe plan.json an, falls nötig — Einheiten und ihr „workout“; garmin_workouts.py \
        baut die Garmin-Workouts daraus. Zeig mir die Einheiten der Woche. Lade noch nichts auf Garmin hoch — das \
        gebe ich danach frei.
        """,
        allowUpload: false, startsConversation: false, needsConversation: false)

    static let uploadWeek = CoachAction(
        id: "upload", title: "Auf Garmin hochladen", symbol: "arrow.up.circle",
        help: "Die besprochene Woche als Workouts auf die Uhr",
        prompt: "Passt so. Lege die vorbereiteten Workouts jetzt auf Garmin an und bestätige kurz, was hochgeladen wurde.",
        allowUpload: true, startsConversation: false, needsConversation: true)

    static let all = [reviewWeek, prepareWeek, uploadWeek]
}

// MARK: - Gesprächsdaten (werden als JSON in Application Support gespeichert)

struct CoachConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Engine, mit der das Gespräch geführt wird (nil = Claude Code, ältere Gespräche).
    var engineID: UUID?
    var engineName: String?
    /// Session bzw. Thread der Engine zum Fortsetzen (Claude: Session-ID, Codex: Thread-ID).
    var engineSessionID: String?
    var turns: [CoachTurn]
}

struct CoachTurn: Identifiable, Codable {
    enum State: String, Codable { case running, done, failed, cancelled }

    let id: UUID
    var title: String?
    var prompt: String
    var allowUpload: Bool
    var startedAt: Date
    var finishedAt: Date?
    var blocks: [CoachBlock]
    var state: State
    var errorMessage: String?
    var deniedTools: [String]
    /// Modell, das tatsächlich geantwortet hat (z. B. „claude-opus-5“), laut Start-Ereignis der CLI.
    var model: String?
    /// Planungsanfrage (für Vorschläge reiner Text-CLIs).
    var planning: TurnPlanning?
    /// Versionsverwaltung: Stand vor und nach dem Lauf, geänderte Dateien.
    var baseCommit: String?
    var commit: String?
    var changedFiles: [String]?
    /// Was sich an plan.json geändert hat (lesbar).
    var planChanges: [String]?
    /// Titel des Entwurfs, falls der Coach plan-entwurf.json geschrieben hat.
    var draftTitle: String?
    /// Stand, der die Änderungen dieses Laufs zurückgenommen hat.
    var revertCommit: String?
    /// JSON-Vorschlag einer reinen Text-CLI und ob er übernommen wurde.
    var proposal: PlanProposal?
    var proposalApplied: Bool?

    /// Der Agent hat signalisiert, dass als Nächstes ein Garmin-Upload anstünde.
    var suggestsUpload: Bool {
        !allowUpload && blocks.last(where: { $0.kind == .text })?.text.contains(CoachContext.uploadMarker) == true
    }
}

struct TurnPlanning: Codable, Hashable {
    var kind: PlanRequest.Kind
    var week: Int
}

struct CoachBlock: Identifiable, Codable {
    enum Kind: String, Codable { case text, tool }
    enum StepState: String, Codable { case running, done, failed }

    let id: String
    var kind: Kind
    /// Antworttext bzw. Beschreibung des Werkzeug-Aufrufs.
    var text: String
    var toolName: String?
    var state: StepState?
}

// MARK: - Modell

@MainActor
@Observable
final class CoachModel {
    private(set) var conversations: [CoachConversation] = []
    private(set) var currentID: UUID?
    private(set) var runningTurnID: UUID?
    private(set) var connections: [McpStatus] = []
    private(set) var limitNote: String?
    var draft = ""
    var allowUpload = false

    /// Hinterlegte CLIs (Einstellungen → Coach).
    var engines: [CoachEngine] {
        didSet {
            if engines.isEmpty { engines = [.claudePreset()] }
            EngineStore.save(engines)
        }
    }
    /// Engine für neue Gespräche.
    private(set) var selectedEngineID: UUID?

    /// Wird nach jedem Lauf aufgerufen (die Engine hat evtl. Dateien geändert).
    var onRunFinished: (@MainActor () -> Void)?
    /// Aktueller Trainingsstand für Engines, die keine Dateien lesen können.
    var snapshotProvider: (@MainActor () -> TrainingSnapshot?)?
    /// Versionsverwaltung des Trainingsordners: Stand vor und nach jedem Lauf.
    var history: ProjectHistory?

    private var runner: (any CoachRunner)?
    private var cancelRequested = false
    private var streamingBlockID: String?

    init() {
        engines = EngineStore.load()
        selectedEngineID = EngineStore.selectedID
        load()
        // Ein kürzlich geführtes Gespräch gleich wieder öffnen.
        if let latest = conversations.first, latest.updatedAt > .now.addingTimeInterval(-12 * 3600) {
            currentID = latest.id
        }
        // Beim Beenden der App keinen CLI-Prozess verwaist weiterlaufen lassen.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runner?.cancel() }
        }
    }

    var isRunning: Bool { runningTurnID != nil }

    var current: CoachConversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var selectedEngine: CoachEngine {
        engines.first { $0.id == selectedEngineID } ?? engines[0]
    }

    /// Engine des offenen Gesprächs bzw. die gewählte für ein neues.
    var activeEngine: CoachEngine {
        if let conversation = current, let engine = engine(of: conversation) { return engine }
        return selectedEngine
    }

    /// Beschreibung des gerade laufenden Schritts, z. B. "Strava: Aktivitäten abrufen".
    var liveStep: String? {
        guard let runningTurnID, let turn = current?.turns.first(where: { $0.id == runningTurnID }) else { return nil }
        return turn.blocks.last(where: { $0.kind == .tool && $0.state == .running })?.text
    }

    func engine(of conversation: CoachConversation) -> CoachEngine? {
        guard let id = conversation.engineID else { return engines.first { $0.kind == .claudeCode } }
        return engines.first { $0.id == id }
    }

    /// Engine wechseln — ein offenes Gespräch einer anderen Engine wird geschlossen.
    func selectEngine(_ id: UUID) {
        guard !isRunning else { return }
        selectedEngineID = id
        EngineStore.selectedID = id
        if let conversation = current, engine(of: conversation)?.id != id {
            currentID = nil
        }
        if !selectedEngine.kind.isAgent { allowUpload = false }
    }

    func newConversation() {
        guard !isRunning else { return }
        currentID = nil
        draft = ""
        allowUpload = false
    }

    func select(_ id: UUID) {
        guard !isRunning else { return }
        currentID = id
    }

    func cancel() {
        cancelRequested = true
        runner?.cancel()
    }

    // MARK: Senden

    func run(_ action: CoachAction, in folder: URL) {
        guard !isRunning, activeEngine.kind.isAgent else { return }
        if action.startsConversation { currentID = nil }
        if action.needsConversation && current == nil { return }
        send(prompt: action.prompt, title: action.title, allowUpload: action.allowUpload, in: folder)
    }

    /// Planungsanfrage: Agenten ändern plan.json bzw. schreiben einen Entwurf, Text-CLIs schlagen JSON vor.
    func plan(_ request: PlanRequest, snapshot: TrainingSnapshot, in folder: URL) {
        guard !isRunning else { return }
        let engine = activeEngine
        if request.kind == .block { currentID = nil }
        let prompt = engine.kind.isAgent
            ? PlanPrompts.agentPrompt(for: request, snapshot: snapshot)
            : PlanPrompts.textPrompt(for: request, snapshot: snapshot, folder: folder)
        let week = request.kind == .session
            ? (request.sessionID.flatMap(snapshot.session(id:))?.week ?? request.week) : request.week
        send(prompt: prompt, title: PlanPrompts.title(for: request, snapshot: snapshot), allowUpload: false, in: folder,
             planning: TurnPlanning(kind: request.kind, week: week))
    }

    func sendDraft(in folder: URL) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        send(prompt: text, title: nil, allowUpload: allowUpload && activeEngine.kind.isAgent, in: folder)
        draft = ""
        allowUpload = false
    }

    /// Wiederholt eine Anfrage, die an fehlender Garmin-Freigabe gescheitert ist.
    func retryWithUpload(in folder: URL) {
        send(prompt: "Du hast jetzt die Freigabe für Garmin. Führe den Schritt aus, der eben blockiert war.",
             title: "Mit Garmin-Freigabe wiederholen", allowUpload: true, in: folder)
    }

    private func send(prompt: String, title: String?, allowUpload: Bool, in folder: URL, planning: TurnPlanning? = nil) {
        guard !isRunning else { return }
        let engine = activeEngine

        // Offenes Gespräch nur fortsetzen, wenn es zur Engine passt.
        var conversation: CoachConversation
        if let open = current, self.engine(of: open)?.id == engine.id {
            conversation = open
        } else {
            conversation = CoachConversation(
                id: UUID(), title: title ?? Self.shortTitle(prompt), createdAt: .now, updatedAt: .now,
                engineID: engine.id, engineName: engine.summary, engineSessionID: nil, turns: [])
        }
        let earlier = conversation.turns
        let turn = CoachTurn(id: UUID(), title: title, prompt: prompt, allowUpload: allowUpload, startedAt: .now,
                             finishedAt: nil, blocks: [], state: .running, errorMessage: nil, deniedTools: [],
                             planning: planning)
        conversation.turns.append(turn)
        conversation.updatedAt = .now
        upsert(conversation)
        currentID = conversation.id

        // Anfrage passend zur Engine zusammensetzen.
        var text = allowUpload ? prompt + CoachContext.uploadRelease : prompt
        var system = CoachContext.agentInstructions(for: engine.kind)
        switch engine.kind {
        case .claudeCode:
            break   // Anweisungen gehen per --append-system-prompt mit
        case .codex:
            if conversation.engineSessionID == nil {
                text = system + "\n\n---\n\n" + text
            }
        case .textCLI:
            system = planning == nil ? CoachContext.textInstructions : CoachContext.textPlanningInstructions
            let context = CoachContext.training(snapshotProvider?(), level: engine.context, folder: folder)
            // Bei „Ausführlich“ steckt das Profil schon in der mitgeschickten README.
            let profile = engine.context == .compact ? CoachContext.athleteProfile(folder: folder) ?? "" : ""
            text = [profile, context, CoachContext.history(earlier), "# Neue Nachricht\n\(prompt)"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        let request = CoachRequest(
            engine: engine,
            workingDirectory: folder,
            prompt: text,
            systemPrompt: system,
            resumeSessionID: conversation.engineSessionID,
            newSessionID: conversation.id,
            sessionName: "Pace Lab: \(conversation.title)",
            allowGarminWrite: allowUpload && engine.kind.isAgent)

        let runner = CoachRunners.make(for: engine.kind)
        self.runner = runner
        runningTurnID = turn.id
        cancelRequested = false
        streamingBlockID = nil
        limitNote = nil
        connections = []
        let conversationID = conversation.id
        let projectHistory = self.history
        let commitMessage = Self.commitMessage(title: title, prompt: prompt, engine: engine, conversation: conversation.title)

        Task {
            // Stand vor dem Lauf festhalten (inkl. Änderungen, die inzwischen außerhalb der App passiert sind).
            if let base = try? await projectHistory?.checkpoint() {
                mutateTurn(turn.id, in: conversationID) { $0.baseCommit = base }
            }
            do {
                for try await event in runner.run(request) {
                    apply(event, turn: turn.id, conversation: conversationID)
                }
                if cancelRequested {
                    finish(turn.id, in: conversationID, state: .cancelled, error: nil)
                } else if self.turn(turn.id, in: conversationID)?.state == .running {
                    finish(turn.id, in: conversationID, state: .done, error: nil)
                }
            } catch {
                finish(turn.id, in: conversationID, state: cancelRequested ? .cancelled : .failed,
                       error: cancelRequested ? nil : error.localizedDescription)
            }
            if engine.kind == .textCLI {
                mutateTurn(turn.id, in: conversationID) { turn in
                    for i in turn.blocks.indices where turn.blocks[i].kind == .text {
                        turn.blocks[i].text = CoachContext.removeThinking(turn.blocks[i].text)
                    }
                    turn.blocks.removeAll { $0.kind == .text && $0.text.isEmpty }
                }
                if let planning, let finished = self.turn(turn.id, in: conversationID), finished.state == .done,
                   let current = snapshotProvider?()?.plan {
                    let answer = finished.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                    let proposal = PlanProposal.extract(from: answer, request: planning.kind, week: planning.week, current: current)
                    mutateTurn(turn.id, in: conversationID) { $0.proposal = proposal }
                }
            }
            // Was der Lauf geändert hat, als eigenen Stand festhalten.
            if let projectHistory {
                await recordChanges(of: turn.id, in: conversationID, history: projectHistory, message: commitMessage)
            }
            self.runner = nil
            runningTurnID = nil
            save()
            onRunFinished?()
        }
    }

    /// Nach einem Lauf: Stand festhalten, geänderte Dateien und Plan-Änderungen am Turn vermerken.
    private func recordChanges(of turnID: UUID, in conversationID: UUID, history: ProjectHistory, message: String) async {
        guard let commit = try? await history.commit(message) else { return }
        let base = turn(turnID, in: conversationID)?.baseCommit
        var files: [String] = []
        if let base { files = (try? await history.changedFiles(from: base, to: commit)) ?? [] }
        var planChanges: [String]?
        if files.contains(TrainingFiles.plan), let data = await history.contents(of: TrainingFiles.plan, at: commit),
           let new = try? PlanFiles.decode(data) {
            var old: TrainingPlan?
            if let base, let before = await history.contents(of: TrainingFiles.plan, at: base) {
                old = try? PlanFiles.decode(before)
            }
            planChanges = PlanDiff.changes(from: old, to: new)
        }
        var draftTitle: String?
        if files.contains(PlanFiles.draft), let data = await history.contents(of: PlanFiles.draft, at: commit) {
            draftTitle = (try? PlanFiles.decode(data))?.title ?? "Entwurf"
        }
        mutateTurn(turnID, in: conversationID) { turn in
            turn.commit = commit
            turn.changedFiles = files
            turn.planChanges = planChanges
            turn.draftTitle = draftTitle
        }
        save()
    }

    /// Nach dem Löschen (eines Teils) des Verlaufs: Verweise auf Stände umschreiben; gelöschte fallen weg,
    /// damit kein „Rückgängig“ auf einen Stand zeigt, den es nicht mehr gibt.
    func remapCommits(_ mapping: [String: String]) {
        for c in conversations.indices {
            for t in conversations[c].turns.indices {
                conversations[c].turns[t].commit = conversations[c].turns[t].commit.flatMap { mapping[$0] }
                conversations[c].turns[t].baseCommit = conversations[c].turns[t].baseCommit.flatMap { mapping[$0] }
                conversations[c].turns[t].revertCommit = conversations[c].turns[t].revertCommit.flatMap { mapping[$0] }
            }
        }
        save()
    }

    // MARK: Gespräche löschen

    func deleteConversation(_ id: UUID) {
        guard !(isRunning && currentID == id) else { return }
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        save()
    }

    func deleteAllConversations() {
        guard !isRunning else { return }
        conversations.removeAll()
        currentID = nil
        draft = ""
        save()
    }

    /// Vermerkt, dass die Änderungen eines Laufs zurückgenommen wurden.
    func markReverted(turn turnID: UUID, commit: String) {
        guard let conversationID = conversation(containing: turnID) else { return }
        mutateTurn(turnID, in: conversationID) { $0.revertCommit = commit }
        save()
    }

    /// Vermerkt, dass der Vorschlag einer Text-CLI übernommen wurde.
    func markProposalApplied(turn turnID: UUID) {
        guard let conversationID = conversation(containing: turnID) else { return }
        mutateTurn(turnID, in: conversationID) { $0.proposalApplied = true }
        save()
    }

    private func conversation(containing turnID: UUID) -> UUID? {
        conversations.first { $0.turns.contains { $0.id == turnID } }?.id
    }

    private static func commitMessage(title: String?, prompt: String, engine: CoachEngine, conversation: String) -> String {
        let subject = "Coach (\(engine.name)): \(title ?? shortTitle(prompt))"
        let request = prompt.count > 1_500 ? String(prompt.prefix(1_499)) + "…" : prompt
        return "\(subject)\n\nAnfrage:\n\(request)\n\nEngine: \(engine.summary)\nGespräch: \(conversation)"
    }

    private func apply(_ event: CoachEvent, turn turnID: UUID, conversation conversationID: UUID) {
        switch event {
        case .started(let model, let servers):
            connections = servers.filter { ["strava-mcp", "garmin-workouts"].contains($0.name) }
            if let model, !model.isEmpty {
                mutateTurn(turnID, in: conversationID) { $0.model = model }
            }
        case .session(let id):
            mutate(conversationID) { $0.engineSessionID = id }
        case .text(let text):
            streamingBlockID = nil
            mutateTurn(turnID, in: conversationID) {
                $0.blocks.append(CoachBlock(id: UUID().uuidString, kind: .text, text: text))
            }
        case .textDelta(let chunk):
            mutateTurn(turnID, in: conversationID) { turn in
                if let id = streamingBlockID, let i = turn.blocks.firstIndex(where: { $0.id == id }) {
                    turn.blocks[i].text += chunk
                } else {
                    let id = UUID().uuidString
                    streamingBlockID = id
                    turn.blocks.append(CoachBlock(id: id, kind: .text, text: chunk))
                }
            }
        case .toolStarted(let id, let name, let label):
            streamingBlockID = nil
            mutateTurn(turnID, in: conversationID) {
                $0.blocks.append(CoachBlock(id: id, kind: .tool, text: label, toolName: name, state: .running))
            }
        case .toolFinished(let id, let failed):
            mutateTurn(turnID, in: conversationID) { turn in
                if let i = turn.blocks.firstIndex(where: { $0.id == id }) {
                    turn.blocks[i].state = failed ? .failed : .done
                }
            }
        case .rateLimited(let status):
            limitNote = status == "rejected"
                ? "Dein Nutzungslimit ist erreicht — später erneut versuchen."
                : "Dein Nutzungslimit ist bald erreicht."
        case .finished(let result):
            mutateTurn(turnID, in: conversationID) { turn in
                turn.deniedTools = result.deniedTools
                if !result.isError, !turn.blocks.contains(where: { $0.kind == .text }),
                   let message = result.message, !message.isEmpty {
                    turn.blocks.append(CoachBlock(id: UUID().uuidString, kind: .text, text: message))
                }
            }
            finish(turnID, in: conversationID, state: result.isError ? .failed : .done,
                   error: result.isError ? (result.message ?? "Die Engine meldet einen Fehler.") : nil)
        }
    }

    private func finish(_ turnID: UUID, in conversationID: UUID, state: CoachTurn.State, error: String?) {
        mutateTurn(turnID, in: conversationID) { turn in
            turn.state = state
            turn.errorMessage = error
            turn.finishedAt = .now
            for i in turn.blocks.indices where turn.blocks[i].state == .running {
                turn.blocks[i].state = state == .done ? .done : .failed
            }
        }
        mutate(conversationID) { $0.updatedAt = .now }
        save()
    }

    // MARK: Test (Einstellungen)

    /// Kurzer Probelauf einer Engine, ohne Gespräch und ohne Spuren in dessen Verlauf.
    func test(_ engine: CoachEngine, in folder: URL) async -> (ok: Bool, message: String) {
        let request = CoachRequest(
            engine: engine, workingDirectory: folder,
            prompt: "Antworte nur mit dem Wort: bereit",
            systemPrompt: engine.kind.isAgent ? "Antworte knapp auf Deutsch." : "Du antwortest knapp auf Deutsch.",
            resumeSessionID: nil, newSessionID: UUID(), sessionName: "Pace Lab: Test",
            allowGarminWrite: false, ephemeral: true)
        let started = Date.now
        var answer = ""
        var failure: String?
        do {
            for try await event in CoachRunners.make(for: engine.kind).run(request) {
                switch event {
                case .text(let text): answer += text
                case .textDelta(let chunk): answer += chunk
                case .finished(let result) where result.isError: failure = result.message ?? "Fehler"
                default: break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        if let failure { return (false, failure) }
        let seconds = Date.now.timeIntervalSince(started)
        let reply = CoachContext.removeThinking(answer)
        return (true, "Antwort: „\(reply.prefix(80))“ · \(seconds.formatted(.number.precision(.fractionLength(1)).locale(Fmt.de))) s")
    }

    // MARK: Hilfen

    private func turn(_ id: UUID, in conversationID: UUID) -> CoachTurn? {
        conversations.first { $0.id == conversationID }?.turns.first { $0.id == id }
    }

    private func upsert(_ conversation: CoachConversation) {
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }

    private func mutate(_ id: UUID, _ change: (inout CoachConversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
    }

    private func mutateTurn(_ turnID: UUID, in conversationID: UUID, _ change: (inout CoachTurn) -> Void) {
        mutate(conversationID) { conversation in
            guard let t = conversation.turns.firstIndex(where: { $0.id == turnID }) else { return }
            change(&conversation.turns[t])
        }
    }

    private static func shortTitle(_ prompt: String) -> String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    // MARK: Speichern

    private static var storeURL: URL {
        AppSettings.supportDirectory.appending(path: "coach.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              var stored = try? JSONDecoder().decode([CoachConversation].self, from: data) else { return }
        // Beim Beenden unterbrochene Läufe als abgebrochen markieren.
        for c in stored.indices {
            for t in stored[c].turns.indices where stored[c].turns[t].state == .running {
                stored[c].turns[t].state = .cancelled
            }
        }
        conversations = stored.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        let recent = Array(conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(40))
        do {
            try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recent).write(to: Self.storeURL, options: .atomic)
        } catch {
            // Verlauf ist Komfort — ein Fehler hier darf den Coach nicht stören.
        }
    }
}
