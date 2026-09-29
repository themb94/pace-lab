import SwiftUI

struct CoachView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteCurrent = false
    @State private var confirmDeleteAll = false

    var body: some View {
        let coach = model.coach
        VStack(spacing: 0) {
            if let conversation = coach.current, !conversation.turns.isEmpty {
                CoachTranscript(conversation: conversation)
            } else {
                CoachWelcome()
            }
            Divider()
            CoachComposer()
        }
        .background(Color.pageBackground)
        .navigationTitle(coach.current?.title ?? "Coach")
        .navigationSubtitle(coach.isRunning ? "\(coach.activeEngine.name) arbeitet …" : model.models.summary(for: coach.activeEngine))
        .task(id: coach.activeEngine) { await model.models.refreshIfStale(coach.activeEngine, folder: model.folder.url) }
        .toolbar {
            ToolbarItemGroup {
                ConnectionBadges(servers: coach.connections)
                EnginePicker()
                Menu {
                    Button("Neues Gespräch") { coach.newConversation() }
                    if coach.current != nil {
                        Button("Dieses Gespräch löschen …", role: .destructive) { confirmDeleteCurrent = true }
                    }
                    if !coach.conversations.isEmpty {
                        Button("Alle Gespräche löschen …", role: .destructive) { confirmDeleteAll = true }
                    }
                    if !coach.conversations.isEmpty { Divider() }
                    ForEach(coach.conversations.prefix(20)) { conversation in
                        Button {
                            coach.select(conversation.id)
                        } label: {
                            Text("\(conversation.title) · \(conversation.engineName ?? "Claude Code") · \(conversation.updatedAt.formatted(.dateTime.day().month().hour().minute().locale(Fmt.de)))")
                        }
                    }
                } label: {
                    Label("Gespräche", systemImage: "clock.arrow.circlepath")
                }
                .help("Frühere Gespräche")
                .disabled(coach.isRunning)
                .confirmationDialog("„\(coach.current?.title ?? "Gespräch")“ löschen?", isPresented: $confirmDeleteCurrent) {
                    Button("Löschen", role: .destructive) {
                        if let id = coach.current?.id { coach.deleteConversation(id) }
                    }
                } message: {
                    Text("Das Gespräch verschwindet aus der App. Änderungen, die der Coach dabei gemacht hat, bleiben — im Bereich „Verlauf“ lassen sie sich weiter zurücknehmen.")
                }
                .confirmationDialog("Alle \(coach.conversations.count) Gespräche löschen?", isPresented: $confirmDeleteAll) {
                    Button("Alle löschen", role: .destructive) { coach.deleteAllConversations() }
                } message: {
                    Text("Die Gespräche verschwinden aus der App. Plan, Läufe und der Verlauf der Stände bleiben unverändert.")
                }

                Button {
                    coach.newConversation()
                } label: {
                    Label("Neues Gespräch", systemImage: "square.and.pencil")
                }
                .help("Neues Gespräch beginnen")
                .disabled(coach.isRunning)
            }
        }
    }
}

/// Auswahl der CLI, mit der der Coach arbeitet.
private struct EnginePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coach = model.coach
        Menu {
            ForEach(coach.engines) { engine in
                Button {
                    coach.selectEngine(engine.id)
                } label: {
                    if engine.id == coach.activeEngine.id {
                        Label(model.models.summary(for: engine), systemImage: "checkmark")
                    } else {
                        Text(model.models.summary(for: engine))
                    }
                }
            }
            Divider()
            SettingsLink { Text("CLIs verwalten …") }
        } label: {
            Label(coach.activeEngine.name, systemImage: coach.activeEngine.kind.symbol)
                .labelStyle(.titleAndIcon)
        }
        .help("Engine wählen — ein Wechsel beginnt ein neues Gespräch")
        .disabled(coach.isRunning)
    }
}

// MARK: - Begrüßung

private struct CoachWelcome: View {
    @Environment(AppModel.self) private var model
    @State private var found: Bool?

    var body: some View {
        let engine = model.coach.activeEngine
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: engine.kind.symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Color.brand)
                Text("Dein Lauf-Coach")
                    .font(.largeTitle.bold())
                Text(intro(for: engine))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 600)

                if engine.kind.isAgent {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach([CoachAction.reviewWeek, .prepareWeek]) { action in
                            Button {
                                model.startCoach(action)
                            } label: {
                                WelcomeCard(symbol: action.symbol, title: action.title, text: action.help)
                            }
                            .buttonStyle(CardButtonStyle())
                            .disabled(model.coach.isRunning || model.sync.isRunning || found == false)
                        }
                        Button {
                            model.requestPlan(.week)
                        } label: {
                            WelcomeCard(symbol: "wand.and.stars", title: "Planen",
                                        text: "Woche umbauen, Einheit ändern oder einen neuen Block entwerfen")
                        }
                        .buttonStyle(CardButtonStyle())
                        .disabled(model.coach.isRunning || model.snapshot == nil || found == false)
                    }
                    Text("Oder schreib unten einfach, was los ist — z. B. „Stadtlauf am Samstag, bau die Woche um“ oder „Beine schwer, was heißt das für Donnerstag?“")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                } else {
                    Label(engine.kind.capabilities, systemImage: "info.circle")
                        .font(.callout)
                        .frame(maxWidth: 560)
                        .card(padding: 14)
                    Text("Frag z. B. „Was steht diese Woche an?“ oder „Wie war mein letzter Long Run?“ — oder lass dir über „Planen“ einen Vorschlag machen, den die App nach deiner Zustimmung übernimmt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                    Button {
                        model.requestPlan(.week)
                    } label: {
                        Label("Planen …", systemImage: "wand.and.stars")
                    }
                    .disabled(model.coach.isRunning || model.snapshot == nil || found == false)
                }

                if found == false {
                    VStack(spacing: 8) {
                        Label(CoachError.notFound(engine.command.isEmpty ? engine.name : engine.command).localizedDescription,
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        SettingsLink { Text("Einstellungen öffnen …") }
                    }
                    .card(tint: .orange)
                    .frame(maxWidth: 560)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .task(id: engine) {
            let command = engine.command
            found = await Task.detached { CLIResolver.find(command) != nil }.value
        }
    }

    private func intro(for engine: CoachEngine) -> String {
        switch engine.kind {
        case .claudeCode:
            "Der Coach ist Claude Code auf deinem Mac — mit derselben README, demselben Gedächtnis und derselben Strava- und Garmin-Verbindung wie im Chat. Was er an Plan und Analysen ändert, siehst du sofort in der App."
        case .codex:
            "Der Coach ist Codex auf deinem Mac — er arbeitet im Trainingsordner nach der README. Was er an Plan und Analysen ändert, siehst du sofort in der App."
        case .textCLI:
            "Der Coach ist „\(engine.name)“. Die App schickt ihm deinen aktuellen Trainingsstand mit."
        }
    }
}

private struct WelcomeCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.brand)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 210, alignment: .leading)
        .card()
    }
}

// MARK: - Verlauf

private struct CoachTranscript: View {
    let conversation: CoachConversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(conversation.turns) { turn in
                        TurnView(turn: turn)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: progress) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Ändert sich bei jedem neuen Block, neuem Text oder Statuswechsel → mitscrollen.
    private var progress: Int {
        conversation.turns.reduce(0) { sum, turn in
            sum + turn.blocks.count * 4 + (turn.blocks.last?.text.count ?? 0) / 200 + (turn.state == .running ? 0 : 1)
        }
    }
}

private struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: CoachTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 120)
                request
            }

            ForEach(pieces) { piece in
                switch piece.content {
                case .text(let text):
                    MarkdownView(text: text.replacingOccurrences(of: CoachContext.uploadMarker, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                case .tools(let steps):
                    StepsView(steps: steps, collapsible: turn.state != .running && steps.count > 3)
                }
            }

            if turn.state == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.coach.liveStep ?? "\(model.coach.activeEngine.name) denkt nach …")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stopp") { model.coach.cancel() }
                        .controlSize(.small)
                }
            }

            footer
        }
    }

    private var request: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let title = turn.title {
                Label(title, systemImage: CoachAction.all.first { $0.title == title }?.symbol
                      ?? turn.planning?.kind.symbol ?? "sparkles")
                    .font(.headline)
                    .help(turn.prompt)
            } else {
                Text(turn.prompt)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if turn.allowUpload {
                Label("Garmin-Upload freigegeben", systemImage: "applewatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.brand.opacity(0.13), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var footer: some View {
        switch turn.state {
        case .running:
            EmptyView()
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                if let proposal = turn.proposal {
                    ProposalCard(turn: turn, proposal: proposal)
                } else if turn.planning != nil && !model.coach.activeEngine.kind.isAgent && turn.commit == nil {
                    Label("In der Antwort war kein gültiger JSON-Vorschlag — frag nach, ob der Coach den Plan als JSON-Codeblock schicken kann.",
                          systemImage: "questionmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if turn.commit != nil || turn.changedFiles?.isEmpty == false {
                    ChangesCard(turn: turn)
                }
                if turn.suggestsUpload {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch")
                            .font(.title2)
                            .foregroundStyle(Color.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Workouts auf Garmin anlegen?").font(.headline)
                            Text("Der Coach darf das erst nach deiner Freigabe.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.startCoach(.uploadWeek)
                        } label: {
                            Label("Freigeben & hochladen", systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brand)
                        .disabled(model.coach.isRunning)
                    }
                    .card(tint: .brand, padding: 12)
                }
                if !garminDenied.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Nicht ausgeführt, weil nicht freigegeben: \(garminDenied.map(ToolLabel.label(for:)).joined(separator: ", "))",
                              systemImage: "lock.fill")
                        Button {
                            model.coach.retryWithUpload(in: model.folder.url)
                        } label: {
                            Label("Mit Garmin-Freigabe wiederholen", systemImage: "arrow.up.circle")
                        }
                        .disabled(model.coach.isRunning)
                    }
                    .font(.callout)
                    .card(tint: .orange, padding: 12)
                }
                Text(doneText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label(turn.errorMessage ?? "Fehlgeschlagen.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if turn.commit != nil { ChangesCard(turn: turn) }
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 8) {
                Label("Abgebrochen", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if turn.commit != nil { ChangesCard(turn: turn) }
            }
        }
    }

    private var garminDenied: [String] {
        turn.deniedTools.filter { ClaudeCodeRunner.garminWriteTools.contains($0) }
    }

    private var doneText: String {
        guard let end = turn.finishedAt else { return "Fertig" }
        let seconds = Int(end.timeIntervalSince(turn.startedAt))
        let duration = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        let used = turn.model.map { " · \(model.models.version(forResolved: $0))" } ?? ""
        return "Fertig · \(duration) · \(end.formatted(.dateTime.hour().minute().locale(Fmt.de)))\(used)"
    }

    /// Aufeinanderfolgende Werkzeug-Schritte zu einem Block zusammenfassen.
    private var pieces: [Piece] {
        var result: [Piece] = []
        for block in turn.blocks {
            switch block.kind {
            case .text:
                result.append(Piece(id: block.id, content: .text(block.text)))
            case .tool:
                if case .tools(let steps) = result.last?.content {
                    result[result.count - 1].content = .tools(steps + [block])
                } else {
                    result.append(Piece(id: block.id, content: .tools([block])))
                }
            }
        }
        return result
    }

    private struct Piece: Identifiable {
        enum Content {
            case text(String)
            case tools([CoachBlock])
        }
        let id: String
        var content: Content
    }
}

/// Was der Coach in diesem Lauf geändert hat — mit Rückgängig.
private struct ChangesCard: View {
    @Environment(AppModel.self) private var model
    let turn: CoachTurn
    @State private var confirmUndo = false
    @State private var offerRestore = false
    @State private var working = false

    var body: some View {
        let files = turn.changedFiles ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: turn.revertCommit == nil ? "doc.badge.clock" : "arrow.uturn.backward.circle")
                    .foregroundStyle(turn.revertCommit == nil ? Color.brand : .secondary)
                Text(turn.revertCommit == nil ? "Geändert: \(files.joined(separator: ", "))" : "Zurückgenommen: \(files.joined(separator: ", "))")
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if turn.revertCommit == nil && turn.commit != nil {
                    if working { ProgressView().controlSize(.small) }
                    Button {
                        confirmUndo = true
                    } label: {
                        Label("Rückgängig", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .disabled(working || model.coach.isRunning || model.sync.isRunning)
                } else if turn.commit == nil && turn.revertCommit == nil {
                    Text("Stand aus dem Verlauf gelöscht")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let changes = turn.planChanges, !changes.isEmpty, turn.revertCommit == nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes.prefix(8), id: \.self) { line in
                        Label(line, systemImage: "calendar")
                            .font(.callout)
                            .labelStyle(CompactLabelStyle())
                    }
                    if changes.count > 8 {
                        Text("… und \(changes.count - 8) weitere Änderungen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.showDraft = false
                    model.section = .plan
                } label: {
                    Label("Im Plan ansehen", systemImage: "calendar")
                }
                .controlSize(.small)
            }
            if let title = turn.draftTitle, turn.revertCommit == nil, model.draft != nil {
                HStack {
                    Label("Entwurf für den nächsten Block: \(title)", systemImage: "pencil.and.list.clipboard")
                        .font(.callout)
                    Spacer()
                    Button("Entwurf ansehen") {
                        model.showDraft = true
                        model.section = .plan
                    }
                    .controlSize(.small)
                }
            }
        }
        .card(tint: turn.revertCommit == nil ? .brand : nil, padding: 12)
        .confirmationDialog("Änderungen dieses Coach-Laufs zurücknehmen?", isPresented: $confirmUndo) {
            Button("Rückgängig machen") { Task { await undo(force: false) } }
        } message: {
            Text("Betroffen: \(files.joined(separator: ", ")). Das Zurücknehmen wird selbst als Stand im Verlauf festgehalten.")
        }
        .confirmationDialog("Spätere Änderungen betreffen dieselben Stellen", isPresented: $offerRestore) {
            Button("Dateien auf den Stand vor dem Coach setzen", role: .destructive) { Task { await undo(force: true) } }
        } message: {
            Text("Dabei gehen auch spätere Änderungen an \(files.joined(separator: ", ")) verloren (sie bleiben im Verlauf nachlesbar).")
        }
    }

    private func undo(force: Bool) async {
        working = true
        let outcome = await model.undo(turn, force: force)
        working = false
        if case .conflict = outcome { offerRestore = true }
    }
}

/// Plan-Vorschlag einer reinen Text-CLI — übernehmen erst nach Zustimmung.
private struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let turn: CoachTurn
    let proposal: PlanProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.brand)
                Text(title).font(.headline)
                Spacer()
                if turn.proposalApplied == true {
                    Label("Übernommen", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Button {
                        model.apply(proposal, from: turn)
                    } label: {
                        Label(buttonTitle, systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .disabled(model.coach.isRunning)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(proposal.changes.prefix(10), id: \.self) { line in
                    Label(line, systemImage: "calendar")
                        .font(.callout)
                        .labelStyle(CompactLabelStyle())
                }
                if proposal.changes.isEmpty {
                    Text("Der Vorschlag entspricht dem aktuellen Plan.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .card(tint: .brand, padding: 12)
    }

    private var title: String {
        switch proposal.scope {
        case .week(let week): "Vorschlag für Woche \(week)"
        case .draft: "Vorschlag für einen neuen Block"
        }
    }

    private var buttonTitle: String {
        switch proposal.scope {
        case .week: "In den Plan übernehmen"
        case .draft: "Als Entwurf ablegen"
        }
    }
}

private struct StepsView: View {
    let steps: [CoachBlock]
    let collapsible: Bool
    @State private var expanded = false

    var body: some View {
        if collapsible {
            DisclosureGroup(isExpanded: $expanded) {
                list.padding(.top, 4)
            } label: {
                Label("\(steps.count) Arbeitsschritte", systemImage: "gearshape.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                HStack(spacing: 7) {
                    Group {
                        switch step.state {
                        case .running: ProgressView().controlSize(.mini)
                        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.orange)
                        default: Image(systemName: "checkmark.circle").foregroundStyle(.green.opacity(0.8))
                        }
                    }
                    .frame(width: 14)
                    Text(step.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

// MARK: - Eingabe

private struct CoachComposer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var coach = model.coach
        let isAgent = coach.activeEngine.kind.isAgent
        VStack(alignment: .leading, spacing: 10) {
            if let note = coach.limitNote {
                Label(note, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                ForEach(CoachAction.all) { action in
                    Button {
                        model.startCoach(action)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .help(isAgent ? action.help : "Braucht Claude Code oder Codex — eine reine Text-CLI kann keine Läufe abrufen oder Dateien ändern.")
                    .disabled(!isAgent || coach.isRunning || model.sync.isRunning || (action.needsConversation && coach.current == nil))
                }
                Button {
                    model.requestPlan(.week)
                } label: {
                    Label("Planen …", systemImage: "wand.and.stars")
                }
                .help("Woche anpassen, Einheit ändern oder neuen Block entwerfen")
                .disabled(coach.isRunning || model.sync.isRunning || model.snapshot == nil)
                Spacer()
                if isAgent {
                    Toggle(isOn: $coach.allowUpload) {
                        Text("Garmin-Upload erlauben")
                    }
                    .toggleStyle(.checkbox)
                    .help("Nur für die nächste Nachricht: Der Coach darf Workouts auf Garmin anlegen, einplanen oder löschen.")
                } else {
                    Label("Nur Text — bekommt deinen Trainingsstand mitgeschickt", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Nachricht an \(coach.activeEngine.name) …", text: $coach.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cardBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            }
                    }
                if coach.isRunning {
                    Button {
                        coach.cancel()
                    } label: {
                        Label("Stopp", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else {
                    Button(action: send) {
                        Label("Senden", systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(coach.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sync.isRunning)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard !model.sync.isRunning else { return }
        model.coach.sendDraft(in: model.folder.url)
    }
}

private struct ConnectionBadges: View {
    let servers: [McpStatus]

    var body: some View {
        if !servers.isEmpty {
            HStack(spacing: 10) {
                ForEach(servers, id: \.name) { server in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(server.isConnected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(server.name == "strava-mcp" ? "Strava" : server.name == "garmin-workouts" ? "Garmin" : server.name)
                    }
                    .help(server.isConnected ? "\(server.name): verbunden" : "\(server.name): \(server.status)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
    }
}
