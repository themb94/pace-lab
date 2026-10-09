import AppKit
import Observation

/// Predefined requests for the weekly routine: review → prepare → upload.
/// Require an agent (Claude Code or Codex).
struct CoachAction: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let help: String
    let prompt: String
    let allowUpload: Bool
    /// Always starts a new conversation (the review is the start of the weekly cycle).
    let startsConversation: Bool
    /// Only useful in an ongoing conversation (e.g. uploading the week just discussed).
    let needsConversation: Bool

    static let reviewWeek = CoachAction(
        id: "review", title: String(localized: "Review week"), symbol: "chart.bar.doc.horizontal",
        help: String(localized: "Fetch runs, tick them off and analyze them"),
        prompt: String(localized: """
        Do the weekly review for the most recently completed training week, exactly as described in README.md: \
        fetch runs (Strava or Garmin, as set in the README), update completed.json and analysis.json and \
        write a week summary into weekSummaries. Runs the app has already loaded (entries with “source” and \
        without “verdict”) you complete instead of creating them anew. Don’t create any Garmin workouts. At the end, answer \
        with a short summary: which runs, your rating and your recommendation for next week.
        """),
        allowUpload: false, startsConversation: true, needsConversation: false)

    static let prepareWeek = CoachAction(
        id: "prepare", title: String(localized: "Prepare next week"), symbol: "calendar.badge.plus",
        help: String(localized: "Check and adjust the plan, show a preview — no upload yet"),
        prompt: String(localized: """
        Prepare the next training week: take the latest review and everything I told you about \
        this week into account. Adjust plan.json if needed — sessions and their “workout”; garmin_workouts.py \
        builds the Garmin workouts from it. Show me the sessions of the week. Don’t upload anything to Garmin yet — I \
        will approve that afterwards.
        """),
        allowUpload: false, startsConversation: false, needsConversation: false)

    static let uploadWeek = CoachAction(
        id: "upload", title: String(localized: "Upload to Garmin"), symbol: "arrow.up.circle",
        help: String(localized: "Send the week we discussed to the watch as workouts"),
        prompt: String(localized: "Looks good. Create the prepared workouts on Garmin now and briefly confirm what was uploaded."),
        allowUpload: true, startsConversation: false, needsConversation: true)

    static let all = [reviewWeek, prepareWeek, uploadWeek]
}

// MARK: - Conversation data (stored as JSON in Application Support)

struct CoachConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Engine the conversation runs on (nil = Claude Code, older conversations).
    var engineID: UUID?
    var engineName: String?
    /// Engine session or thread to resume (Claude: session ID, Codex: thread ID).
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
    /// Model that actually answered (e.g. "claude-opus-5"), per the CLI's start event.
    var model: String?
    /// Planning request (for suggestions from plain text CLIs).
    var planning: TurnPlanning?
    /// Version history: state before and after the run, changed files.
    var baseCommit: String?
    var commit: String?
    var changedFiles: [String]?
    /// What changed in plan.json (human-readable).
    var planChanges: [String]?
    /// Title of the draft, if the coach wrote plan-entwurf.json.
    var draftTitle: String?
    /// Commit that reverted this run's changes.
    var revertCommit: String?
    /// JSON suggestion from a plain text CLI and whether it was applied.
    var proposal: PlanProposal?
    var proposalApplied: Bool?

    /// The agent signaled that a Garmin upload would be next.
    var suggestsUpload: Bool {
        !allowUpload && blocks.last(where: { $0.kind == .text }).map { block in CoachContext.uploadMarkers.contains { block.text.contains($0) } } == true
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
    /// Reply text or description of the tool call.
    var text: String
    var toolName: String?
    var state: StepState?
}

// MARK: - Model

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

    /// Configured CLIs (Settings → Coach).
    var engines: [CoachEngine] {
        didSet {
            if engines.isEmpty { engines = [.claudePreset()] }
            EngineStore.save(engines)
        }
    }
    /// Engine for new conversations.
    private(set) var selectedEngineID: UUID?

    /// Called after every run (the engine may have changed files).
    var onRunFinished: (@MainActor () -> Void)?
    /// Current training state for engines that can't read files.
    var snapshotProvider: (@MainActor () -> TrainingSnapshot?)?
    /// Version history of the training folder: state before and after every run.
    var history: ProjectHistory?

    private var runner: (any CoachRunner)?
    private var cancelRequested = false
    private var streamingBlockID: String?

    init() {
        engines = EngineStore.load()
        selectedEngineID = EngineStore.selectedID
        load()
        // Reopen a recent conversation right away.
        if let latest = conversations.first, latest.updatedAt > .now.addingTimeInterval(-12 * 3600) {
            currentID = latest.id
        }
        // Don't leave a CLI process running orphaned when the app quits.
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

    /// Engine of the open conversation, or the selected one for a new conversation.
    var activeEngine: CoachEngine {
        if let conversation = current, let engine = engine(of: conversation) { return engine }
        return selectedEngine
    }

    /// Description of the step currently running, e.g. "Strava: fetching activities".
    var liveStep: String? {
        guard let runningTurnID, let turn = current?.turns.first(where: { $0.id == runningTurnID }) else { return nil }
        return turn.blocks.last(where: { $0.kind == .tool && $0.state == .running })?.text
    }

    func engine(of conversation: CoachConversation) -> CoachEngine? {
        guard let id = conversation.engineID else { return engines.first { $0.kind == .claudeCode } }
        return engines.first { $0.id == id }
    }

    /// Switch engine — an open conversation of another engine gets closed.
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

    // MARK: Sending

    func run(_ action: CoachAction, in folder: URL) {
        guard !isRunning, activeEngine.kind.isAgent else { return }
        if action.startsConversation { currentID = nil }
        if action.needsConversation && current == nil { return }
        send(prompt: action.prompt, title: action.title, allowUpload: action.allowUpload, in: folder)
    }

    /// Planning request: agents change plan.json or write a draft, text CLIs suggest JSON.
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

    /// Retries a request that failed because of missing Garmin permission.
    func retryWithUpload(in folder: URL) {
        send(prompt: String(localized: "You now have approval for Garmin. Carry out the step that was just blocked."),
             title: String(localized: "Repeat with Garmin approval"), allowUpload: true, in: folder)
    }

    private func send(prompt: String, title: String?, allowUpload: Bool, in folder: URL, planning: TurnPlanning? = nil) {
        guard !isRunning else { return }
        let engine = activeEngine

        // Only continue the open conversation if it belongs to the engine.
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

        // Build the request to suit the engine.
        var text = allowUpload ? prompt + CoachContext.uploadRelease : prompt
        var system = CoachContext.agentInstructions(for: engine.kind)
        switch engine.kind {
        case .claudeCode:
            break   // instructions are passed via --append-system-prompt
        case .codex:
            if conversation.engineSessionID == nil {
                text = system + "\n\n---\n\n" + text
            }
        case .textCLI:
            system = planning == nil ? CoachContext.textInstructions : CoachContext.textPlanningInstructions
            let context = CoachContext.training(snapshotProvider?(), level: engine.context, folder: folder)
            // With "Detailed", the profile is already part of the attached README.
            let profile = engine.context == .compact ? CoachContext.athleteProfile(folder: folder) ?? "" : ""
            text = [profile, context, CoachContext.history(earlier), "# New message\n\(prompt)"]
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
            // Record the state before the run (including changes made outside the app in the meantime).
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
            // Record what the run changed as its own commit.
            if let projectHistory {
                await recordChanges(of: turn.id, in: conversationID, history: projectHistory, message: commitMessage)
            }
            self.runner = nil
            runningTurnID = nil
            save()
            onRunFinished?()
        }
    }

    /// After a run: record the state, note changed files and plan changes on the turn.
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
            draftTitle = (try? PlanFiles.decode(data))?.title ?? String(localized: "Draft")
        }
        mutateTurn(turnID, in: conversationID) { turn in
            turn.commit = commit
            turn.changedFiles = files
            turn.planChanges = planChanges
            turn.draftTitle = draftTitle
        }
        save()
    }

    /// After deleting (part of) the history: rewrite references to commits; deleted ones are dropped
    /// so that no "Undo" points to a commit that no longer exists.
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

    // MARK: Deleting conversations

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

    /// Notes that a run's changes were reverted.
    func markReverted(turn turnID: UUID, commit: String) {
        guard let conversationID = conversation(containing: turnID) else { return }
        mutateTurn(turnID, in: conversationID) { $0.revertCommit = commit }
        save()
    }

    /// Notes that a text CLI's suggestion was applied.
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
        return String(localized: "\(subject)\n\nRequest:\n\(request)\n\nEngine: \(engine.summary)\nConversation: \(conversation)")
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
                ? String(localized: "Your usage limit has been reached — try again later.")
                : String(localized: "Your usage limit will be reached soon.")
        case .finished(let result):
            mutateTurn(turnID, in: conversationID) { turn in
                turn.deniedTools = result.deniedTools
                if !result.isError, !turn.blocks.contains(where: { $0.kind == .text }),
                   let message = result.message, !message.isEmpty {
                    turn.blocks.append(CoachBlock(id: UUID().uuidString, kind: .text, text: message))
                }
            }
            finish(turnID, in: conversationID, state: result.isError ? .failed : .done,
                   error: result.isError ? (result.message ?? String(localized: "The engine reports an error.")) : nil)
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

    // MARK: Test (Settings)

    /// Short trial run of an engine, without a conversation and without leaving traces in its history.
    func test(_ engine: CoachEngine, in folder: URL) async -> (ok: Bool, message: String) {
        let request = CoachRequest(
            engine: engine, workingDirectory: folder,
            prompt: "Reply only with the word: ready",
            systemPrompt: "Answer briefly in \(CoachContext.replyLanguage).",
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
                case .finished(let result) where result.isError: failure = result.message ?? String(localized: "Error")
                default: break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        if let failure { return (false, failure) }
        let seconds = Date.now.timeIntervalSince(started)
        let reply = CoachContext.removeThinking(answer)
        return (true, String(localized: "Reply: “\(reply.prefix(80))” · \(seconds.formatted(.number.precision(.fractionLength(1)).locale(Fmt.locale))) s"))
    }

    // MARK: Helpers

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

    // MARK: Saving

    /// Conversations of the profile that was active when the model was created.
    private let storeURL = ActiveProfile.current.dataDirectory.appending(path: "coach.json")

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var stored = try? JSONDecoder().decode([CoachConversation].self, from: data) else { return }
        // Mark runs interrupted by quitting as cancelled.
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
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recent).write(to: storeURL, options: .atomic)
        } catch {
            // History is a convenience — an error here must not disrupt the coach.
        }
    }
}
