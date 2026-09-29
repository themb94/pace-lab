import SwiftUI
import WidgetKit

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Allgemein", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Läufe", systemImage: "arrow.down.circle", value: "runs") {
                RunSourceSettings()
            }
            Tab("Coach", systemImage: "sparkles", value: "coach") {
                CoachSettings()
            }
        }
        .frame(width: 800)
    }
}

// MARK: - Allgemein

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.Key.projectPath) private var projectPath = AppSettings.defaultProjectPath
    @AppStorage(AppSettings.Key.athleteName) private var athleteName = ""
    @State private var historyCount: Int?
    @State private var historyError: String?
    @State private var settingUp = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Ordner") {
                    Text(projectPath)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Button("Auswählen …", action: chooseFolder)
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: projectPath)])
                    }
                }
                ForEach(["plan.json", "analysis.json", "completed.json", "README.md", ".mcp.json"], id: \.self) { name in
                    let found = FileManager.default.fileExists(atPath: URL(filePath: projectPath).appending(path: name).path)
                    Label(name, systemImage: found ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(found ? Color.primary : Color.orange)
                }
            } header: {
                Text("Trainingsordner")
            } footer: {
                Text("Die App liest und schreibt die Dateien direkt dort — dieselben, die auch der Coach benutzt.")
            }

            Section {
                TextField("Dein Name", text: $athleteName, prompt: Text("so spricht dich der Coach an"))
                Button("Einrichtung öffnen …") { openWindow(id: "setup") }
            } header: {
                Text("Über dich")
            } footer: {
                Text("Ziel, Maximalpuls und Besonderheiten stehen im Athletenprofil der README im Trainingsordner.")
            }

            Section {
                if model.history.isRepository {
                    Label(historyCount.map { "Aktiv — \($0) Stände festgehalten" } ?? "Aktiv", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Verlauf öffnen") {
                        model.section = .history
                        openWindow(id: "main")
                    }
                } else {
                    Label("Aus", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Einrichten") {
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
                Text("Versionsverwaltung (git)")
            } footer: {
                Text("Die App hält vor und nach jedem Coach-Lauf, bei Häkchen, geladenen Läufen und übernommenen Plänen einen Stand fest. Unter „Verlauf“ siehst du jede Änderung und kannst sie zurücknehmen. Alles bleibt lokal im Ordner (.git) — nichts wird hochgeladen.")
            }

            Section {
                Button("Widgets jetzt aktualisieren") {
                    model.reload(force: true)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Die Widgets zeigen den Stand, den die App zuletzt gelesen hat. Solange Pace Lab läuft (auch nur in der Menüleiste), aktualisiert sie die Widgets bei jeder Änderung automatisch.")
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
        panel.prompt = "Auswählen"
        panel.message = "Wähle den Ordner mit plan.json, analysis.json und completed.json."
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }
}

// MARK: - Läufe laden

private struct RunSourceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SyncSettings.Key.source) private var source = RunSource.garmin.rawValue
    @AppStorage(SyncSettings.Key.stravaModel) private var stravaModel = SyncSettings.defaultStravaModel
    @AppStorage(SyncSettings.Key.autoAssign) private var autoAssign = true
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                Picker("Läufe holen von", selection: $source) {
                    ForEach(RunSource.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Text(source == RunSource.strava.rawValue
                     ? "Claude Code ruft im Hintergrund nur die beiden Strava-Lese-Werkzeuge auf; die App übernimmt die Rohdaten direkt aus der Antwort. Dauert etwa 10–20 Sekunden und zählt minimal aufs Claude-Kontingent."
                     : "Die App startet den Garmin-Server aus der .mcp.json im Nur-Lese-Modus und fragt die letzten Läufe direkt ab — ohne Sprachmodell und ohne Kontingent. Dauert ein paar Sekunden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Quelle")
            } footer: {
                Text("„Läufe laden“ (⌘R, Knopf oben links) holt alle Läufe ab drei Tagen vor dem neuesten gespeicherten und trägt neue in analysis.json ein — noch ohne Bewertung. Ein Lauf, der schon von der anderen Quelle da ist, wird erkannt und nicht doppelt eingetragen.")
            }

            if source == RunSource.strava.rawValue {
                Section("Claude Code") {
                    Picker("Modell", selection: $stravaModel) {
                        ForEach(stravaChoices, id: \.value) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    LabeledContent("Programm", value: model.claudeCommand)
                }
            }

            Section {
                Toggle("Workout-Läufe automatisch zuordnen und abhaken", isOn: $autoAssign)
            } footer: {
                Text("Garmin übernimmt den Workout-Namen (z. B. „PL W01 · 6x800m“) in den Lauf — daran erkennt die App die Einheit eindeutig. Andere Läufe ordnest du unter Läufe → „Zuordnen“ zu oder überlässt es dem Coach bei der Auswertung.")
            }

            Section {
                HStack {
                    Button("Verbindung prüfen", action: check)
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Jetzt laden") { model.syncRuns() }
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
        .frame(height: 560)
        .onChange(of: source) { result = nil }
    }

    /// Modelle der Claude-Code-Engine; haiku reicht für die zwei Werkzeug-Aufrufe.
    private var stravaChoices: [(value: String, title: String)] {
        var choices: [(value: String, title: String)]
        if let models = model.models.models(for: model.claudeEngine) {
            choices = (models.options + models.pinned).map { option in
                let title = option.value.isEmpty ? "Standard — \(option.version)"
                    : option.value == option.resolved ? "\(option.version) (fest)" : "\(option.name) — \(option.version)"
                return (option.value, title + (option.value == SyncSettings.defaultStravaModel ? " · empfohlen" : ""))
            }
        } else {
            choices = [("haiku", "Haiku · empfohlen"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("", "Standard der CLI")]
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
        let isStrava = source == RunSource.strava.rawValue
        Task {
            if isStrava {
                let check = await Task.detached { ConnectionCheck.run(command: command, folder: folder) }.value
                if let strava = check.lines.first {
                    result = (strava.ok, strava.text)
                }
            } else {
                do {
                    guard let config = GarminServerConfig.load(from: folder) else {
                        throw SyncFailure(message: "Keine .mcp.json mit „garmin-workouts“ im Trainingsordner.")
                    }
                    let client = try await config.connect(in: folder, readOnly: true)
                    let text = try await client.callTool("garmin_status", timeout: 60)
                    client.close()
                    result = (!text.hasPrefix("❌"), text.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
                } catch {
                    result = (false, error.localizedDescription)
                }
            }
            checking = false
        }
    }
}

// MARK: - Coach: hinterlegte CLIs

private struct CoachSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        @Bindable var coach = model.coach
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Hinterlegte CLIs") {
                        ForEach(coach.engines) { engine in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(engine.name)
                                        if engine.id == coach.selectedEngine.id {
                                            Text("Standard").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
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
                        Button("Lokales Modell (LM Studio / Bionic)") { add(.lmStudioPreset()) }
                        Divider()
                        Button("Eigene CLI …") { add(.customPreset()) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 30)
                    .help("CLI hinzufügen")

                    Button {
                        remove()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    .disabled(coach.engines.count <= 1 || selection == nil)
                    .help("Ausgewählte CLI entfernen")
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
                ContentUnavailableView("CLI auswählen", systemImage: "terminal",
                                       description: Text("Links eine CLI wählen oder mit + eine neue hinzufügen."))
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
                Picker("Typ", selection: $engine.kind) {
                    ForEach(CoachEngine.Kind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                Text(engine.kind.capabilities)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Programm") {
                HStack {
                    TextField("Programm", text: $engine.executable, prompt: Text(programPrompt))
                    Button("Auswählen …", action: chooseProgram)
                }
                Group {
                    if resolving {
                        Label("Suche …", systemImage: "magnifyingglass")
                    } else if let resolvedPath {
                        Label("Gefunden: \(resolvedPath)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if !engine.command.isEmpty {
                        Label("„\(engine.command)“ nicht gefunden — vollständigen Pfad eintragen.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            if engine.kind == .textCLI {
                Section("Modell") {
                    HStack {
                        TextField("Modell", text: $engine.model, prompt: Text("Standard der CLI"))
                        localModelMenu
                    }
                }
            } else {
                Section {
                    LabeledContent("Modell") {
                        ModelMenu(value: $engine.model, models: model.models.models(for: engine))
                    }
                    if let details = selectedOption?.details, !details.isEmpty {
                        Text(details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if effortChoices.isEmpty {
                        LabeledContent("Denktiefe", value: "bei diesem Modell nicht einstellbar")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Denktiefe", selection: $engine.effort) {
                            Text("Standard").tag("")
                            ForEach(effortChoices, id: \.self) { Text(ModelName.effortLabel($0)).tag($0) }
                        }
                    }
                    DisclosureGroup("Anderes Modell eintragen") {
                        TextField("Modellname", text: $engine.model,
                                  prompt: Text(engine.kind == .claudeCode ? "voller Name, z. B. claude-opus-4-6" : "z. B. gpt-5.5"))
                    }
                } header: {
                    Text("Modell")
                } footer: {
                    modelFooter
                }
            }

            if engine.kind == .textCLI {
                Section {
                    TextField("Argumente", text: $engine.arguments, prompt: Text("z. B. run {model} oder chat {model} -p {prompt}"))
                    TextField("Vorher ausführen", text: $engine.prepareCommand, prompt: Text("optional, z. B. lms load {model} -y"))
                    Picker("Trainingsstand mitschicken", selection: $engine.context) {
                        ForEach(CoachEngine.ContextLevel.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Aufruf")
                } footer: {
                    Text("Platzhalter: {model}, {prompt} = deine Frage mit Trainingsstand und Verlauf, {system} = Anweisungen an den Coach. Ohne {prompt} geht die Frage über die Standardeingabe, ohne {system} stehen die Anweisungen vor der Frage. Beispiele: Ollama „run {model}“, LM Studio/Bionic „chat {model} -p {prompt} -s {system}“.")
                }
            } else {
                Section {
                    TextField("Zusätzliche Argumente", text: $engine.arguments, prompt: Text("optional"))
                } footer: {
                    Text(engine.kind == .codex
                         ? "Für ein lokales Modell über Codex z. B. „--oss --local-provider lmstudio“ (dann Modell = LM-Studio-Modell). Codex kann sich nicht bei Strava anmelden und holt Läufe direkt über Garmin."
                         : "Wird an den Aufruf von Claude Code angehängt, z. B. „--fallback-model sonnet“.")
                }
            }

            Section {
                HStack {
                    Button("Testen", action: runTest)
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if engine.kind == .claudeCode {
                        Button("Strava/Garmin prüfen", action: checkConnections)
                    }
                    Spacer()
                    Button("Für neue Gespräche verwenden") { model.coach.selectEngine(engine.id) }
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
                Text("Der Test schickt „Antworte nur mit dem Wort: bereit“. Bei Claude und Codex zählt das minimal aufs Kontingent, lokale Modelle werden dafür geladen.")
            }
        }
        .formStyle(.grouped)
        .task(id: engine.command) { await resolveProgram() }
        .task(id: "\(engine.kind.rawValue)|\(engine.command)") {
            await model.models.refresh(engine, folder: model.folder.url)
        }
        .onChange(of: engine.model) {
            // Eine Denktiefe, die das neue Modell nicht kennt, zurücksetzen.
            if !engine.effort.isEmpty && !effortChoices.contains(engine.effort) { engine.effort = "" }
        }
    }

    private var programPrompt: String {
        engine.kind.defaultCommand.isEmpty ? "z. B. lms, ollama oder /pfad/zum/programm" : "automatisch (\(engine.kind.defaultCommand))"
    }

    /// Lokale Modelle (LM Studio / Bionic) — nur auf Knopfdruck, weil die Abfrage LM Studio weckt.
    private var localModelMenu: some View {
        Menu {
            Button("Standard der CLI") { engine.model = "" }
            Divider()
            if localModels.isEmpty {
                Button(loadingLocalModels ? "Lade …" : "Modelle aus LM Studio / Bionic abrufen", action: fetchLocalModels)
                    .disabled(loadingLocalModels)
            } else {
                ForEach(localModels, id: \.self) { name in Button(name) { engine.model = name } }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Vorschläge")
    }

    private var selectedOption: ModelOption? {
        model.models.models(for: engine)?.option(for: engine.model)
    }

    /// Denktiefen des gewählten Modells; unbekannte Modelle bekommen die übliche Auswahl.
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
                    Text("\(engine.kind == .claudeCode ? "Claude Code" : "Codex") \(models.cliVersion) · Stand \(models.fetchedAt.formatted(.dateTime.day().month().hour().minute().locale(Fmt.de)))")
                    Button("Aktualisieren") {
                        Task { await store.refresh(engine, folder: model.folder.url, force: true) }
                    }
                    .buttonStyle(.link)
                    .disabled(store.isLoading(engine))
                    if store.isLoading(engine) { ProgressView().controlSize(.mini) }
                }
                Text(engine.kind == .claudeCode
                     ? "Die Liste kommt direkt aus der installierten Claude-Code-Version. „Immer das neueste“ wandert mit Updates mit (opus zeigt dann z. B. auf 5.5), eine feste Version bleibt."
                     : "Die Liste kommt aus Codex' eigener Modellliste für dein Konto.")
            } else if store.isLoading(engine) {
                Label("Frage die verfügbaren Modelle ab …", systemImage: "hourglass")
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
        panel.treatsFilePackagesAsDirectories = true   // auch CLIs innerhalb von Apps (z. B. Bionic)
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
        panel.prompt = "Auswählen"
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
        Task {
            connections = await Task.detached { ConnectionCheck.run(command: command, folder: folder) }.value
        }
    }
}

/// Prüft bei Claude Code die Strava- und Garmin-Anbindung, ohne das Modell aufzurufen.
struct ConnectionCheck: Sendable {
    struct Line: Sendable {
        let text: String
        let ok: Bool
    }

    let lines: [Line]

    static func run(command: String, folder: URL) -> ConnectionCheck {
        guard let exe = CLIResolver.find(command) else {
            return ConnectionCheck(lines: [Line(text: CoachError.notFound(command).localizedDescription, ok: false)])
        }
        var lines: [Line] = []
        let list = CLIResolver.runSync(exe, ["mcp", "list"], in: folder)
        if let strava = list.split(separator: "\n").first(where: { $0.hasPrefix("strava-mcp") }) {
            let ok = strava.contains("Connected")
            lines.append(Line(text: ok ? "Strava verbunden" : "Strava: \(strava.split(separator: " - ").last ?? "nicht verbunden")", ok: ok))
        } else {
            lines.append(Line(text: "Strava-MCP ist für diesen Ordner nicht eingerichtet", ok: false))
        }

        if let data = try? Data(contentsOf: folder.appending(path: ".mcp.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = config["mcpServers"] as? [String: Any],
           let garmin = servers["garmin-workouts"] as? [String: Any],
           let program = garmin["command"] as? String {
            let ok = FileManager.default.isExecutableFile(atPath: program)
            lines.append(Line(text: ok ? "Garmin-Server gefunden (wird beim Start geladen)" : "Garmin: \(program) fehlt", ok: ok))
        } else {
            lines.append(Line(text: "Garmin: keine .mcp.json im Ordner", ok: false))
        }
        return ConnectionCheck(lines: lines)
    }
}
