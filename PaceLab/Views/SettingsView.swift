import SwiftUI
import WidgetKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        // General, Runs and Coach belong to the active profile and start fresh after a switch.
        let profile = model.profile
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings(defaults: profile.defaults).id(profile.id)
            }
            Tab("Runs", systemImage: "arrow.down.circle", value: SettingsTab.runs) {
                RunSourceSettings(defaults: profile.defaults).id(profile.id)
            }
            Tab("Coach", systemImage: "sparkles", value: SettingsTab.coach) {
                CoachSettings().id(profile.id)
            }
            Tab("Profiles", systemImage: "person.2", value: SettingsTab.profiles) {
                ProfileSettings()
            }
        }
        .frame(width: 800)
    }
}

// MARK: - Allgemein

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage private var projectPath: String
    @State private var historyCount: Int?
    @State private var historyError: String?
    @State private var folderError: String?
    @State private var settingUp = false

    /// `defaults`: settings of the active profile.
    init(defaults: UserDefaults) {
        _projectPath = AppStorage(wrappedValue: AppSettings.defaultProjectPath, AppSettings.Key.projectPath, store: defaults)
    }

    private var athleteName: Binding<String> {
        Binding(get: { model.profile.name }, set: { model.profiles.rename(model.profiles.activeID, to: $0) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(projectPath)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Button("Choose …", action: chooseFolder)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: projectPath)])
                    }
                }
                if let folderError {
                    Label(folderError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(["plan.json", "analysis.json", "completed.json", "README.md", ".mcp.json"], id: \.self) { name in
                    let found = FileManager.default.fileExists(atPath: URL(filePath: projectPath).appending(path: name).path)
                    Label(name, systemImage: found ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(found ? Color.primary : Color.orange)
                }
            } header: {
                Text(model.profiles.hasSeveral ? String(localized: "Training folder of “\(model.profile.displayName)”") : String(localized: "Training folder"))
            } footer: {
                Text("The app reads and writes the files right there — the same ones the coach uses.")
            }

            Section {
                TextField("Your name", text: athleteName, prompt: Text("how the coach addresses you"))
                Button("Open setup …") { openWindow(id: "setup") }
            } header: {
                Text("About you")
            } footer: {
                Text("The name is also the name of the profile. Goal, max heart rate and special considerations are in the athlete profile of the README in the training folder.")
            }

            Section {
                if model.history.isRepository {
                    Label(historyCount.map { "Active — \($0) versions saved" } ?? "Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Open history") {
                        model.section = .history
                        openWindow(id: "main")
                    }
                } else {
                    Label("Off", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Set up") {
                            settingUp = true
                            Task {
                                do { try await model.setUpHistory() } catch { historyError = error.localizedDescription }
                                settingUp = false
                            }
                        }
                        .disabled(settingUp)
                        if settingUp { ProgressView().controlSize(.small) }
                    }
                }
                if let historyError {
                    Text(historyError).foregroundStyle(.orange).textSelection(.enabled)
                }
            } header: {
                Text("Version control (git)")
            } footer: {
                Text("The app records a version before and after every coach run, for ticks, loaded runs and applied plans. Under “History” you see every change and can undo it. Everything stays local in the folder (.git) — nothing is uploaded.")
            }

            Section {
                Button("Update widgets now") {
                    model.reload(force: true)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("The widgets show the state the app last read. As long as Pace Lab is running (even just in the menu bar), it updates the widgets automatically on every change.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onChange(of: projectPath) { model.folderChanged() }
        .task(id: model.historyRevision) {
            historyCount = (try? await model.history.log(limit: 5_000))?.count
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: projectPath)
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder with plan.json, analysis.json and completed.json.")
        if panel.runModal() == .OK, let url = panel.url {
            if let owner = model.profiles.owner(ofFolder: url.path), owner.id != model.profiles.activeID {
                folderError = String(localized: "This folder belongs to the profile “\(owner.displayName)”. Every profile needs its own training folder.")
                return
            }
            folderError = nil
            projectPath = url.path
        }
    }
}

// MARK: - Load runs

private struct RunSourceSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage private var source: String
    @AppStorage private var stravaModel: String
    @AppStorage private var autoAssign: Bool
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?

    /// `defaults`: settings of the active profile.
    init(defaults: UserDefaults) {
        _source = AppStorage(wrappedValue: RunSource.garmin.rawValue, SyncSettings.Key.source, store: defaults)
        _stravaModel = AppStorage(wrappedValue: SyncSettings.defaultStravaModel, SyncSettings.Key.stravaModel, store: defaults)
        _autoAssign = AppStorage(wrappedValue: true, SyncSettings.Key.autoAssign, store: defaults)
    }

    /// Strava or the watch — "garmin"/"polar" stored both mean "the watch".
    private var effectiveSource: RunSource { SyncSettings.source(stored: source, watch: model.watch) }

    var body: some View {
        Form {
            Section {
                Picker("Your watch", selection: Binding(get: { model.watch }, set: { model.setWatch($0) })) {
                    ForEach(WatchKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.watch != .none {
                    HStack {
                        Text(WatchServerConfig.load(from: model.folder.url, watch: model.watch) == nil
                             ? String(localized: "The \(model.watch.label) server isn’t set up for this profile yet.")
                             : String(localized: "\(model.watch.label) server registered in the training folder."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set up \(model.watch.label) …") { openWindow(id: "setup") }
                    }
                }
            } header: {
                Text("Watch")
            } footer: {
                Text(watchFooter)
            }

            Section {
                Picker("Fetch runs from", selection: Binding(get: { effectiveSource }, set: { source = $0.rawValue })) {
                    ForEach([model.watch.runSource, .strava].compactMap { $0 }) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(effectiveSource == .strava
                     ? String(localized: "In the background, Claude Code only calls the two Strava read tools; the app takes the raw data straight from the reply. Takes about 10–20 seconds and counts minimally against your Claude quota.")
                     : String(localized: "The app starts the \(effectiveSource.shortLabel) server from the .mcp.json in read-only mode and queries the latest runs directly — without a language model and without using any quota. Takes a few seconds."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Source")
            } footer: {
                Text("“Load runs” (⌘R, button at the top left) fetches all runs from three days before the newest saved one and adds new ones to analysis.json — without a rating yet. A run that already exists from the other source is recognized and not entered twice.")
            }

            if effectiveSource == .strava {
                Section("Claude Code") {
                    Picker("Model", selection: $stravaModel) {
                        ForEach(stravaChoices, id: \.value) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    LabeledContent("Program", value: model.claudeCommand)
                }
            }

            if effectiveSource == .polar {
                Section {
                    Text("Polar passes on no workout names, so runs can’t be assigned automatically. You assign them under Runs → “Assign” or leave it to the coach during the review.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Toggle("Automatically assign workout runs and tick them off", isOn: $autoAssign)
                } footer: {
                    Text("Garmin copies the workout name (e.g. “PL W01 · 6x800m”) into the run — that is how the app identifies the session unambiguously. You assign other runs under Runs → “Assign” or leave it to the coach during the review.")
                }
            }

            Section {
                HStack {
                    Button("Check connection", action: check)
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Load now") { model.syncRuns() }
                        .disabled(model.sync.isRunning || model.coach.isRunning || model.snapshot == nil)
                }
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? Color.green : Color.orange)
                        .textSelection(.enabled)
                }
                if let step = model.sync.step {
                    Label(step, systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                } else if case .failed(let message) = model.sync.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if case .finished(let summary) = model.sync.state {
                    Label(summary.message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onChange(of: source) { result = nil }
        .onChange(of: model.watch) { result = nil }
    }

    private var watchFooter: String {
        let text = switch model.watch {
        case .garmin: String(localized: "Runs come directly from Garmin Connect, workouts go to the watch after your approval.")
        case .polar: String(localized: "Runs come directly from Polar Flow (read-only). Polar doesn’t let apps put workouts on the watch — the app shows each week as phases to enter in Polar Flow.")
        case .none: String(localized: "Without a watch, runs come from Strava or the coach enters them.")
        }
        return text + " " + String(localized: "Switching keeps the other watch’s setup, so you can switch back at any time.")
    }

    /// Models of the Claude Code engine; haiku is enough for the two tool calls.
    private var stravaChoices: [(value: String, title: String)] {
        var choices: [(value: String, title: String)]
        if let models = model.models.models(for: model.claudeEngine) {
            choices = (models.options + models.pinned).map { option in
                let title = option.value.isEmpty ? String(localized: "Default — \(option.version)")
                    : option.value == option.resolved ? String(localized: "\(option.version) (fixed)") : "\(option.name) — \(option.version)"
                return (option.value, title + (option.value == SyncSettings.defaultStravaModel ? String(localized: " · recommended") : ""))
            }
        } else {
            choices = [("haiku", String(localized: "Haiku · recommended")), ("sonnet", "Sonnet"), ("opus", "Opus"), ("", String(localized: "CLI default"))]
        }
        if !choices.contains(where: { $0.value == stravaModel }) {
            choices.append((stravaModel, ModelName.pretty(stravaModel)))
        }
        return choices
    }

    private func check() {
        checking = true
        result = nil
        let folder = model.folder.url
        let command = model.claudeCommand
        let isStrava = effectiveSource == .strava
        let watch = model.watch
        Task {
            if isStrava {
                let check = await Task.detached { ConnectionCheck.run(command: command, folder: folder, watch: watch) }.value
                if let strava = check.lines.first {
                    result = (strava.ok, strava.text)
                }
            } else {
                result = await WatchCheck.run(watch, folder: folder)
            }
            checking = false
        }
    }
}

// MARK: - Coach: configured CLIs

private struct CoachSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        @Bindable var coach = model.coach
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Configured CLIs") {
                        ForEach(coach.engines) { engine in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(engine.name)
                                        if engine.id == coach.selectedEngine.id {
                                            Text("Default").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                                        }
                                    }
                                    Text("\(engine.kind.label) · \(model.models.label(for: engine))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: engine.kind.symbol)
                            }
                            .tag(engine.id)
                        }
                        .onMove { coach.engines.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        Button("Claude Code") { add(.claudePreset()) }
                        Button("Codex") { add(.codexPreset()) }
                        Button("Local model (LM Studio / Bionic)") { add(.lmStudioPreset()) }
                        Divider()
                        Button("Custom CLI …") { add(.customPreset()) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 30)
                    .help("Add CLI")

                    Button {
                        remove()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    .disabled(coach.engines.count <= 1 || selection == nil)
                    .help("Remove selected CLI")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 250)

            Divider()

            if let index = coach.engines.firstIndex(where: { $0.id == selection }) {
                EngineEditor(engine: $coach.engines[index])
                    .id(coach.engines[index].id)
            } else {
                ContentUnavailableView("Select a CLI", systemImage: "terminal",
                                       description: Text("Choose a CLI on the left or add a new one with +."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 560)
        .onAppear { selection = selection ?? model.coach.activeEngine.id }
    }

    private func add(_ engine: CoachEngine) {
        model.coach.engines.append(engine)
        selection = engine.id
    }

    private func remove() {
        guard let selection, model.coach.engines.count > 1 else { return }
        model.coach.engines.removeAll { $0.id == selection }
        if model.coach.selectedEngine.id == selection, let first = model.coach.engines.first {
            model.coach.selectEngine(first.id)
        }
        self.selection = model.coach.engines.first?.id
    }
}

private struct EngineEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var engine: CoachEngine

    @State private var resolvedPath: String?
    @State private var resolving = false
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var localModels: [String] = []
    @State private var loadingLocalModels = false
    @State private var connections: ConnectionCheck?

    private struct TestResult {
        let ok: Bool
        let message: String
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $engine.name)
                Picker("Type", selection: $engine.kind) {
                    ForEach(CoachEngine.Kind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                Text(engine.kind.capabilities)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Program") {
                HStack {
                    TextField("Program", text: $engine.executable, prompt: Text(programPrompt))
                    Button("Choose …", action: chooseProgram)
                }
                Group {
                    if resolving {
                        Label("Searching …", systemImage: "magnifyingglass")
                    } else if let resolvedPath {
                        Label("Found: \(resolvedPath)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if !engine.command.isEmpty {
                        Label("“\(engine.command)” not found — enter the full path.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            if engine.kind == .textCLI {
                Section("Model") {
                    HStack {
                        TextField("Model", text: $engine.model, prompt: Text("CLI default"))
                        localModelMenu
                    }
                }
            } else {
                Section {
                    LabeledContent("Model") {
                        ModelMenu(value: $engine.model, models: model.models.models(for: engine))
                    }
                    if let details = selectedOption?.details, !details.isEmpty {
                        Text(details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if effortChoices.isEmpty {
                        LabeledContent("Thinking depth", value: String(localized: "not adjustable for this model"))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Thinking depth", selection: $engine.effort) {
                            Text("Default").tag("")
                            ForEach(effortChoices, id: \.self) { Text(ModelName.effortLabel($0)).tag($0) }
                        }
                    }
                    DisclosureGroup("Enter another model") {
                        TextField("Model name", text: $engine.model,
                                  prompt: Text(engine.kind == .claudeCode ? "full name, e.g. claude-opus-4-6" : "e.g. gpt-5.5"))
                    }
                } header: {
                    Text("Model")
                } footer: {
                    modelFooter
                }
            }

            if engine.kind == .textCLI {
                Section {
                    TextField("Arguments", text: $engine.arguments, prompt: Text("e.g. run {model} or chat {model} -p {prompt}"))
                    TextField("Run first", text: $engine.prepareCommand, prompt: Text("optional, e.g. lms load {model} -y"))
                    Picker("Send training status", selection: $engine.context) {
                        ForEach(CoachEngine.ContextLevel.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Invocation")
                } footer: {
                    Text("Placeholders: {model}, {prompt} = your question with training status and history, {system} = instructions for the coach. Without {prompt} the question goes through standard input, without {system} the instructions come before the question. Examples: Ollama “run {model}”, LM Studio/Bionic “chat {model} -p {prompt} -s {system}”.")
                }
            } else {
                Section {
                    TextField("Additional arguments", text: $engine.arguments, prompt: Text("optional"))
                } footer: {
                    Text(engine.kind == .codex
                         ? "For a local model via Codex, e.g. “--oss --local-provider lmstudio” (then model = LM Studio model). Codex can’t sign in to Strava and fetches runs directly through Garmin."
                         : "Appended to the Claude Code call, e.g. “--fallback-model sonnet”.")
                }
            }

            Section {
                HStack {
                    Button("Test", action: runTest)
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if engine.kind == .claudeCode {
                        Button(model.watch == .none ? String(localized: "Check Strava") : String(localized: "Check Strava/\(model.watch.label)"),
                               action: checkConnections)
                    }
                    Spacer()
                    Button("Use for new conversations") { model.coach.selectEngine(engine.id) }
                        .disabled(model.coach.selectedEngine.id == engine.id)
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                        .textSelection(.enabled)
                }
                if let connections {
                    ForEach(connections.lines, id: \.text) { line in
                        Label(line.text, systemImage: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(line.ok ? Color.primary : Color.orange)
                    }
                }
            } footer: {
                Text("The test sends “Reply only with the word: ready”. For Claude and Codex this counts minimally against your quota; local models are loaded for it.")
            }
        }
        .formStyle(.grouped)
        .task(id: engine.command) { await resolveProgram() }
        .task(id: "\(engine.kind.rawValue)|\(engine.command)") {
            await model.models.refresh(engine, folder: model.folder.url)
        }
        .onChange(of: engine.model) {
            // Reset a reasoning effort that the new model doesn't know.
            if !engine.effort.isEmpty && !effortChoices.contains(engine.effort) { engine.effort = "" }
        }
    }

    private var programPrompt: String {
        engine.kind.defaultCommand.isEmpty ? String(localized: "e.g. lms, ollama or /path/to/program") : String(localized: "automatic (\(engine.kind.defaultCommand))")
    }

    /// Local models (LM Studio / Bionic) — only on demand, because the query wakes LM Studio.
    private var localModelMenu: some View {
        Menu {
            Button("CLI default") { engine.model = "" }
            Divider()
            if localModels.isEmpty {
                Button(loadingLocalModels ? "Loading …" : "Fetch models from LM Studio / Bionic", action: fetchLocalModels)
                    .disabled(loadingLocalModels)
            } else {
                ForEach(localModels, id: \.self) { name in Button(name) { engine.model = name } }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Suggestions")
    }

    private var selectedOption: ModelOption? {
        model.models.models(for: engine)?.option(for: engine.model)
    }

    /// Reasoning efforts of the selected model; unknown models get the usual selection.
    private var effortChoices: [String] {
        selectedOption?.efforts ?? ModelCatalog.efforts
    }

    @ViewBuilder
    private var modelFooter: some View {
        let store = model.models
        VStack(alignment: .leading, spacing: 6) {
            if let models = store.models(for: engine) {
                ForEach(models.notices, id: \.self) { notice in
                    Label(notice, systemImage: "arrow.up.circle")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Text("\(engine.kind == .claudeCode ? "Claude Code" : "Codex") \(models.cliVersion) · updated \(models.fetchedAt.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))")
                    Button("Refresh") {
                        Task { await store.refresh(engine, folder: model.folder.url, force: true) }
                    }
                    .buttonStyle(.link)
                    .disabled(store.isLoading(engine))
                    if store.isLoading(engine) { ProgressView().controlSize(.mini) }
                }
                Text(engine.kind == .claudeCode
                     ? "The list comes straight from the installed Claude Code version. “Always the latest” moves along with updates (opus then points to e.g. 5.5), a fixed version stays."
                     : "The list comes from Codex’s own model list for your account.")
            } else if store.isLoading(engine) {
                Label("Querying the available models …", systemImage: "hourglass")
            } else if let error = store.error(for: engine) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    private func resolveProgram() async {
        resolving = true
        let command = engine.command
        resolvedPath = await Task.detached { CLIResolver.find(command)?.path }.value
        resolving = false
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true   // also CLIs inside apps (e.g. Bionic)
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            engine.executable = url.path
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let engine = self.engine
        Task {
            let result = await model.coach.test(engine, in: model.folder.url)
            testResult = TestResult(ok: result.ok, message: result.message)
            testing = false
        }
    }

    private func fetchLocalModels() {
        loadingLocalModels = true
        Task {
            localModels = await Task.detached { ModelCatalog.lmStudioModels() }.value
            loadingLocalModels = false
        }
    }

    private func checkConnections() {
        let command = engine.command
        let folder = model.folder.url
        let watch = model.watch
        Task {
            connections = await Task.detached { ConnectionCheck.run(command: command, folder: folder, watch: watch) }.value
        }
    }
}

/// Checks the Strava and watch connection for Claude Code without calling the model.
struct ConnectionCheck: Sendable {
    struct Line: Sendable {
        let text: String
        let ok: Bool
    }

    let lines: [Line]

    static func run(command: String, folder: URL, watch: WatchKind) -> ConnectionCheck {
        guard let exe = CLIResolver.find(command) else {
            return ConnectionCheck(lines: [Line(text: CoachError.notFound(command).localizedDescription, ok: false)])
        }
        var lines: [Line] = []
        let list = CLIResolver.runSync(exe, ["mcp", "list"], in: folder)
        if let strava = list.split(separator: "\n").first(where: { $0.hasPrefix("strava-mcp") }) {
            let ok = strava.contains("Connected")
            lines.append(Line(text: ok ? String(localized: "Strava connected") : "Strava: \(strava.split(separator: " - ").last.map(String.init) ?? String(localized: "not connected"))", ok: ok))
        } else {
            lines.append(Line(text: String(localized: "Strava MCP is not set up for this folder"), ok: false))
        }

        if watch != .none {
            if let config = WatchServerConfig.load(from: folder, watch: watch) {
                let ok = FileManager.default.isExecutableFile(atPath: config.command)
                lines.append(Line(text: ok ? String(localized: "\(watch.label) server found (loaded at startup)") : String(localized: "\(watch.label): \(config.command) is missing"), ok: ok))
            } else {
                lines.append(Line(text: String(localized: "\(watch.label): not registered in the folder’s .mcp.json"), ok: false))
            }
        }
        return ConnectionCheck(lines: lines)
    }
}
