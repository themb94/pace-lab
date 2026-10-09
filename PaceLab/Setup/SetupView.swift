import SwiftUI

/// Progress text that background work can report.
@MainActor
@Observable
final class ProgressText {
    var text: String?
}

/// Setup: training folder, name, coach CLIs, Garmin and Strava — everything needed before the first plan.
/// Always for the active profile: every profile is set up on its own.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage private var projectPath: String

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

    /// `defaults`: settings of the active profile.
    init(defaults: UserDefaults) {
        _projectPath = AppStorage(wrappedValue: AppSettings.defaultProjectPath, AppSettings.Key.projectPath, store: defaults)
    }

    private var folder: URL { URL(filePath: projectPath, directoryHint: .isDirectory) }

    private var profile: Profile { model.profile }

    private var athleteName: Binding<String> {
        Binding(get: { model.profile.name }, set: { model.profiles.rename(model.profiles.activeID, to: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.profiles.hasSeveral ? String(localized: "Set up “\(profile.displayName)”") : String(localized: "Set up Pace Lab"),
                          systemImage: "figure.run.circle.fill")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.brand)
                    Text("Your data stays on your Mac: in the training folder, in your CLIs and with Garmin or Strava themselves. Garmin and Strava are optional — without them you plan and tick off by hand.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !profile.isMain {
                        Label("This profile is completely separate from the others: its own folder and its own sign-ins. Sign in to the coach, Garmin and Strava here again — even if they are already signed in on this Mac for another profile.",
                              systemImage: "person.crop.circle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                step(1, String(localized: "Training folder"), done: folderReady) { folderStep }
                step(2, String(localized: "About you"), done: !profile.trimmedName.isEmpty) { aboutStep }
                step(3, "Coach", done: claude?.loggedIn == true || codex?.loggedIn == true || lms?.path != nil) { coachStep }
                step(4, "Garmin (optional)", done: garminConfigured != nil && GarminSetup.hasToken) { garminStep }
                step(5, String(localized: "Strava (optional, via Claude Code)"), done: strava == .connected) { stravaStep }
                step(6, String(localized: "Get started"), done: false) { startStep }
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
                Label("Plan, runs and coach README are in place.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("This is where your plan (plan.json), your runs (analysis.json), ticks and the README with the rules for the coach live. The app creates it with an example plan; every change is recorded as a version (git).")
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
                        Label("Create folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .disabled(creating)
                }
                Button("Choose another folder …", action: chooseFolder)
                if folderReady {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                if creating { ProgressView().controlSize(.small) }
            }
            if let folderError { Label(folderError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Your name (how the coach addresses you)", text: athleteName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Text("Goal, max heart rate, training days or special considerations go in the “Athlete profile” section of the README in the training folder. Fill it in or just tell the coach — it will enter it itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open README") { NSWorkspace.shared.open(folder.appending(path: "README.md")) }
                .disabled(!folderReady)
        }
    }

    private var coachStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.isMain
                 ? String(localized: "The coach is a CLI on your Mac that you install yourself and use with your own account. One is enough.")
                 : String(localized: "The coach is a CLI on your Mac that you use with your own account. One is enough. This profile signs in separately — with its own account or one you share."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            cliRow("Claude Code", info: claude, detail: String(localized: "Agent — plans, reviews, Strava and Garmin."),
                   login: "claude auth login", install: "https://docs.claude.com/en/docs/claude-code/setup")
            cliRow("Codex", info: codex, detail: String(localized: "Agent — plans, reviews, Garmin (no Strava)."),
                   login: "codex login", install: "https://developers.openai.com/codex/cli")
            cliRow(String(localized: "Local model (LM Studio / Bionic)"), info: lms, detail: String(localized: "Text only — advises from the status sent along, changes nothing."),
                   login: nil, install: "https://lmstudio.ai")
            HStack {
                Button("Check again") { Task { await refresh() } }
                SettingsLink { Text("Coach settings …") }
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
                        Text("Checking …")
                    } else if let path = info?.path {
                        Text(([info?.version, path].compactMap { $0 }).joined(separator: " · ")
                             + (info?.loggedIn == false ? String(localized: " · not signed in") : info?.loggedIn == true ? String(localized: " · signed in") : ""))
                    } else {
                        Text("not installed")
                    }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if info?.path == nil {
                Link("Install …", destination: URL(string: install)!)
            } else if info?.loggedIn == false, let login {
                Button("Sign in …") { Terminal.run(login, name: "login", profile: profile) }
            }
        }
    }

    private var garminStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For “Load runs” directly from Garmin and to send workouts to your watch. The app installs a small local server for this (needs Python 3.10+). You sign in with your Garmin account; only a token is stored (\(GarminSetup.tokenStore.replacingOccurrences(of: NSHomeDirectory(), with: "~"))), never your password.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let configured = garminConfigured {
                Label("Server registered: \(configured)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout).lineLimit(2)
            }
            HStack {
                Button(garminConfigured == nil ? "Set up Garmin server" : "Reinstall server") { installGarmin() }
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
                TextField("Code from the email / app", text: $login.code).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Confirm") { Task { await login.submitCode() } }
                    .disabled(login.code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { login.cancel() }
            }
        case .working:
            HStack { ProgressView().controlSize(.small); Text("Signing in to Garmin …") }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if GarminSetup.hasToken {
                    Label("Signed in (token present)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                HStack {
                    TextField("Garmin email", text: $login.email).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    SecureField("Password", text: $login.password).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button(GarminSetup.hasToken ? "Sign in again" : "Sign in") { Task { await login.start(folder: folder) } }
                        .disabled(login.email.isEmpty || login.password.isEmpty)
                }
                HStack {
                    Button("Check connection") { checkGarmin() }
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
            Text("Strava is only reachable through Strava’s own MCP server in Claude Code. The app registers it for this folder; you sign in in the browser.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch strava {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Checking …") }
            case .noClaude:
                Label("Needs Claude Code (step 3).", systemImage: "info.circle").foregroundStyle(.secondary)
            case .missing:
                Button("Add Strava to Claude Code") {
                    do { try StravaSetup.add(folder: folder); stravaError = nil } catch { stravaError = error.localizedDescription }
                    Task { await refreshStrava() }
                }
                .disabled(!folderReady)
            case .needsLogin:
                Button("Sign in to Strava …") { StravaSetup.openLogin(folder: folder) }
            case .connected:
                Label("Strava connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unknown(let text):
                Label("Status: \(text)", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                Button("Sign in to Strava …") { StravaSetup.openLogin(folder: folder) }
            }
            HStack {
                Button("Check again") { Task { await refreshStrava() } }
                if strava == .connected || strava == .needsLogin {
                    Text("You choose the source for “Load runs” in Settings → Runs.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let stravaError { Label(stravaError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Have the coach plan your first block of your own — it follows the athlete profile in the README. The example plan is archived in the process.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    model.requestPlan(.block)
                    openWindow(id: "main")
                } label: {
                    Label("Create first plan", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .disabled(!folderReady || model.snapshot == nil)
                Button("Go to the app") { openWindow(id: "main") }
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
        // Model lists depend on the account: query them again once a CLI is signed in (e.g. right after signing in).
        if claude?.loggedIn == true || codex?.loggedIn == true { model.refreshModels(force: true) }
        await refreshStrava()
    }

    private func refreshStrava() async {
        strava = nil
        let folder = self.folder
        strava = await Task.detached { StravaSetup.status(folder: folder) }.value
    }

    private func installGarmin() {
        garminInstalling = String(localized: "Starting …")
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
                guard let config = GarminServerConfig.load(from: folder) else { throw SetupError(String(localized: "No Garmin server registered.")) }
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
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the training folder (or an empty folder where the app will create it).")
        if panel.runModal() == .OK, let url = panel.url {
            if let owner = model.profiles.owner(ofFolder: url.path), owner.id != model.profiles.activeID {
                folderError = String(localized: "This folder belongs to the profile “\(owner.displayName)”. Every profile needs its own training folder.")
                return
            }
            folderError = nil
            projectPath = url.path
            model.folderChanged()
        }
    }
}
