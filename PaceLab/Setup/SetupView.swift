import SwiftUI

/// Fortschrittstext, den Hintergrundarbeit melden kann.
@MainActor
@Observable
final class ProgressText {
    var text: String?
}

/// Einrichtung: Trainingsordner, Name, Coach-CLIs, Garmin und Strava — alles, was vor dem ersten Plan nötig ist.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.Key.projectPath) private var projectPath = AppSettings.defaultProjectPath
    @AppStorage(AppSettings.Key.athleteName) private var athleteName = ""

    @State private var folderReady = false
    @State private var folderError: String?
    @State private var creating = false
    @State private var claude: CLISetup.Info?
    @State private var codex: CLISetup.Info?
    @State private var lms: CLISetup.Info?
    @State private var garminConfigured: String?
    @State private var garminInstalling: String?
    @State private var garminProgress = ProgressText()
    @State private var garminError: String?
    @State private var garminCheck: (ok: Bool, text: String)?
    @State private var login = GarminLogin()
    @State private var strava: StravaSetup.Status?
    @State private var stravaError: String?

    private var folder: URL { URL(filePath: projectPath, directoryHint: .isDirectory) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Pace Lab einrichten", systemImage: "figure.run.circle.fill")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.brand)
                    Text("Deine Daten bleiben auf deinem Mac: im Trainingsordner, in deinen CLIs und bei Garmin bzw. Strava selbst. Garmin und Strava sind optional — ohne sie planst und hakst du von Hand ab.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(1, "Trainingsordner", done: folderReady) { folderStep }
                step(2, "Über dich", done: !athleteName.trimmingCharacters(in: .whitespaces).isEmpty) { aboutStep }
                step(3, "Coach", done: claude?.loggedIn == true || codex?.loggedIn == true || lms?.path != nil) { coachStep }
                step(4, "Garmin (optional)", done: garminConfigured != nil && GarminSetup.hasToken) { garminStep }
                step(5, "Strava (optional, über Claude Code)", done: strava == .connected) { stravaStep }
                step(6, "Loslegen", done: false) { startStep }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color.pageBackground)
        .task(id: projectPath) { await refresh() }
    }

    // MARK: Schritte

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(projectPath).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            if folderReady {
                Label("Plan, Läufe und Coach-README sind da.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Hier liegen dein Plan (plan.json), deine Läufe (analysis.json), Häkchen und die README mit den Regeln für den Coach. Die App legt ihn mit einem Beispielplan an; jede Änderung wird als Stand festgehalten (git).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !folderReady {
                    Button {
                        creating = true
                        Task {
                            do {
                                try await TrainingFolderSetup.create(at: folder)
                                folderError = nil
                                model.folderChanged()
                            } catch {
                                folderError = error.localizedDescription
                            }
                            creating = false
                            await refresh()
                        }
                    } label: {
                        Label("Ordner anlegen", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .disabled(creating)
                }
                Button("Anderen Ordner wählen …", action: chooseFolder)
                if folderReady {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                if creating { ProgressView().controlSize(.small) }
            }
            if let folderError { Label(folderError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Dein Name (so spricht dich der Coach an)", text: $athleteName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Text("Ziel, Maximalpuls, Trainingstage oder Besonderheiten stehen im Abschnitt „Athletenprofil“ der README im Trainingsordner. Füll ihn aus oder erzähl es einfach dem Coach — er trägt es selbst ein.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("README öffnen") { NSWorkspace.shared.open(folder.appending(path: "README.md")) }
                .disabled(!folderReady)
        }
    }

    private var coachStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Der Coach ist eine CLI auf deinem Mac, die du selbst installierst und mit deinem eigenen Konto nutzt. Eine reicht.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            cliRow("Claude Code", info: claude, detail: "Agent — plant, wertet aus, Strava und Garmin.",
                   login: "claude auth login", install: "https://docs.claude.com/en/docs/claude-code/setup")
            cliRow("Codex", info: codex, detail: "Agent — plant, wertet aus, Garmin (kein Strava).",
                   login: "codex login", install: "https://developers.openai.com/codex/cli")
            cliRow("Lokales Modell (LM Studio / Bionic)", info: lms, detail: "Nur Text — berät anhand des mitgeschickten Stands, ändert nichts.",
                   login: nil, install: "https://lmstudio.ai")
            HStack {
                Button("Erneut prüfen") { Task { await refresh() } }
                SettingsLink { Text("Coach-Einstellungen …") }
            }
        }
    }

    private func cliRow(_ name: String, info: CLISetup.Info?, detail: String, login: String?, install: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: info?.path == nil ? "circle.dashed" : info?.loggedIn == false ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle.fill")
                .foregroundStyle(info?.path == nil ? Color.secondary : info?.loggedIn == false ? Color.orange : Color.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Group {
                    if info == nil {
                        Text("Prüfe …")
                    } else if let path = info?.path {
                        Text(([info?.version, path].compactMap { $0 }).joined(separator: " · ")
                             + (info?.loggedIn == false ? " · nicht angemeldet" : info?.loggedIn == true ? " · angemeldet" : ""))
                    } else {
                        Text("nicht installiert")
                    }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if info?.path == nil {
                Link("Installieren …", destination: URL(string: install)!)
            } else if info?.loggedIn == false, let login {
                Button("Anmelden …") { Terminal.run(login, name: "login") }
            }
        }
    }

    private var garminStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für „Läufe laden“ direkt von Garmin und um Workouts auf die Uhr zu schicken. Die App installiert dafür einen kleinen lokalen Server (braucht Python 3.10+). Angemeldet wird mit deinem Garmin-Konto; gespeichert wird nur ein Token in ~/.garminconnect, nie dein Passwort.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let configured = garminConfigured {
                Label("Server eingetragen: \(configured)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout).lineLimit(2)
            }
            HStack {
                Button(garminConfigured == nil ? "Garmin-Server einrichten" : "Server neu installieren") { installGarmin() }
                    .disabled(garminInstalling != nil || !folderReady)
                if garminInstalling != nil { ProgressView().controlSize(.small) }
                if let step = garminInstalling { Text(step).font(.caption).foregroundStyle(.secondary) }
            }
            if let garminError { Label(garminError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }

            if garminConfigured != nil {
                Divider()
                garminLoginForm
            }
        }
    }

    @ViewBuilder
    private var garminLoginForm: some View {
        switch login.phase {
        case .needsCode:
            HStack {
                TextField("Code aus der E-Mail / App", text: $login.code).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Bestätigen") { Task { await login.submitCode() } }
                    .disabled(login.code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Abbrechen") { login.cancel() }
            }
        case .working:
            HStack { ProgressView().controlSize(.small); Text("Melde bei Garmin an …") }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if GarminSetup.hasToken {
                    Label("Angemeldet (Token vorhanden)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                HStack {
                    TextField("Garmin-E-Mail", text: $login.email).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    SecureField("Passwort", text: $login.password).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button(GarminSetup.hasToken ? "Neu anmelden" : "Anmelden") { Task { await login.start(folder: folder) } }
                        .disabled(login.email.isEmpty || login.password.isEmpty)
                }
                HStack {
                    Button("Verbindung prüfen") { checkGarmin() }
                    if let garminCheck {
                        Label(garminCheck.text, systemImage: garminCheck.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(garminCheck.ok ? Color.green : Color.orange).font(.callout).lineLimit(2)
                    }
                }
                if case .done(let text) = login.phase { Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if case .failed(let text) = login.phase { Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
    }

    private var stravaStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Strava ist nur über Stravas eigenen MCP-Server in Claude Code erreichbar. Die App trägt ihn für diesen Ordner ein; angemeldet wird im Browser.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch strava {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Prüfe …") }
            case .noClaude:
                Label("Braucht Claude Code (Schritt 3).", systemImage: "info.circle").foregroundStyle(.secondary)
            case .missing:
                Button("Strava in Claude Code eintragen") {
                    do { try StravaSetup.add(folder: folder); stravaError = nil } catch { stravaError = error.localizedDescription }
                    Task { await refreshStrava() }
                }
                .disabled(!folderReady)
            case .needsLogin:
                Button("Bei Strava anmelden …") { StravaSetup.openLogin(folder: folder) }
            case .connected:
                Label("Strava verbunden", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unknown(let text):
                Label("Status: \(text)", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                Button("Bei Strava anmelden …") { StravaSetup.openLogin(folder: folder) }
            }
            HStack {
                Button("Erneut prüfen") { Task { await refreshStrava() } }
                if strava == .connected || strava == .needsLogin {
                    Text("Quelle für „Läufe laden“ wählst du in den Einstellungen → Läufe.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let stravaError { Label(stravaError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lass dir vom Coach deinen ersten eigenen Block planen — er richtet sich nach dem Athletenprofil in der README. Der Beispielplan wird dabei abgelegt.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    model.requestPlan(.block)
                    openWindow(id: "main")
                } label: {
                    Label("Ersten Plan erstellen", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .disabled(!folderReady || model.snapshot == nil)
                Button("Zur App") { openWindow(id: "main") }
            }
        }
    }

    // MARK: Bausteine

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.brand.opacity(0.18)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.callout.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.bold()).foregroundStyle(Color.brand)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private func refresh() async {
        folderReady = TrainingFolderSetup.isReady(folder)
        let folder = self.folder
        garminConfigured = GarminServerConfig.load(from: folder).map { config in
            (config.arguments.first ?? config.command).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        (claude, codex, lms) = await Task.detached { (CLISetup.claude(), CLISetup.codex(), CLISetup.lmStudio()) }.value
        await refreshStrava()
    }

    private func refreshStrava() async {
        strava = nil
        let folder = self.folder
        strava = await Task.detached { StravaSetup.status(folder: folder) }.value
    }

    private func installGarmin() {
        garminInstalling = "Starte …"
        garminError = nil
        let folder = self.folder
        let tracker = garminProgress
        Task {
            let watch = Task {
                while !Task.isCancelled {
                    if let text = tracker.text { garminInstalling = text }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            do {
                try await Task.detached {
                    try GarminSetup.install { step in Task { @MainActor in tracker.text = step } }
                    try GarminSetup.writeConfig(folder: folder)
                }.value
            } catch {
                garminError = error.localizedDescription
            }
            watch.cancel()
            garminInstalling = nil
            await refresh()
        }
    }

    private func checkGarmin() {
        garminCheck = nil
        let folder = self.folder
        Task {
            do {
                guard let config = GarminServerConfig.load(from: folder) else { throw SetupError("Kein Garmin-Server eingetragen.") }
                let client = try await config.connect(in: folder, readOnly: true)
                let text = try await client.callTool("garmin_status", timeout: 60)
                client.close()
                garminCheck = (!text.hasPrefix("❌"), text.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
            } catch {
                garminCheck = (false, error.localizedDescription)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Auswählen"
        panel.message = "Wähle den Trainingsordner (oder einen leeren Ordner, in dem die App ihn anlegt)."
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
            model.folderChanged()
        }
    }
}
