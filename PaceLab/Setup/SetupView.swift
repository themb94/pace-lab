import SwiftUI

/// Progress text that background work can report.
@MainActor
@Observable
final class ProgressText {
    var text: String?
}

/// Setup: training folder, name, coach CLIs, watch (Garmin or Polar) and Strava — everything needed before the first plan.
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
    @State private var serverConfigured: String?
    @State private var installing: String?
    @State private var installProgress = ProgressText()
    @State private var installError: String?
    @State private var watchCheck: (ok: Bool, text: String)?
    @State private var login = GarminLogin()
    @State private var polar = PolarLogin()
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
                    Text("Your data stays on your Mac: in the training folder, in your CLIs and with Garmin, Polar or Strava themselves. Watch and Strava are optional — without them you plan and tick off by hand.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !profile.isMain {
                        Label("This profile is completely separate from the others: its own folder and its own sign-ins. Sign in to the coach, the watch and Strava here again — even if they are already signed in on this Mac for another profile.",
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
                step(4, String(localized: "Watch"), done: watchReady) { watchStep }
                step(5, String(localized: "Strava (optional, via Claude Code)"), done: strava == .connected) { stravaStep }
                step(6, String(localized: "Get started"), done: false) { startStep }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color.pageBackground)
        .task(id: projectPath) { await refresh() }
        .onChange(of: model.watch) {
            watchCheck = nil
            installError = nil
            Task { await refresh() }
        }
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
            cliRow("Claude Code", info: claude, detail: String(localized: "Agent — plans, reviews, Strava and the watch."),
                   login: "claude auth login", install: "https://docs.claude.com/en/docs/claude-code/setup")
            cliRow("Codex", info: codex, detail: String(localized: "Agent — plans, reviews, the watch (no Strava)."),
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

    private var watchStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Your watch", selection: Binding(get: { model.watch }, set: { model.setWatch($0) })) {
                ForEach(WatchKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Text("You can switch later in Settings → Runs, e.g. after getting a new watch.")
                .font(.caption).foregroundStyle(.secondary)
            switch model.watch {
            case .garmin:
                Text("For “Load runs” directly from Garmin and to send workouts to your watch. The app installs a small local server for this (needs Python 3.10+). You sign in with your Garmin account; only a token is stored (\(abbreviated(WatchSetup.garmin.tokenStore))), never your password.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                serverRow(.garmin)
                if serverConfigured != nil {
                    Divider()
                    garminLoginForm
                }
            case .polar:
                Text("Runs come straight from Polar Flow through Polar’s official interface (AccessLink) — read-only, without a language model. Polar doesn’t let other apps put workouts on the watch: Pace Lab shows each week as phases to enter in Polar Flow instead. The app installs a small local server for this (needs Python 3.10+).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                serverRow(.polar)
                if serverConfigured != nil {
                    Divider()
                    polarLoginForm
                }
            case .none:
                Text("Without a watch connection you load runs from Strava (next step) or let the coach enter them. Workouts are not sent to a watch.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func serverRow(_ setup: WatchSetup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let configured = serverConfigured {
                Label("Server registered: \(configured)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout).lineLimit(2)
            }
            HStack {
                Button(serverConfigured == nil ? String(localized: "Set up \(setup.watch.label) server") : String(localized: "Reinstall server")) { install(setup) }
                    .disabled(installing != nil || !folderReady)
                if installing != nil { ProgressView().controlSize(.small) }
                if let step = installing { Text(step).font(.caption).foregroundStyle(.secondary) }
            }
            if let installError { Label(installError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
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
                if WatchSetup.garmin.hasToken {
                    Label("Signed in (token present)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                HStack {
                    TextField("Garmin email", text: $login.email).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    SecureField("Password", text: $login.password).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button(WatchSetup.garmin.hasToken ? "Sign in again" : "Sign in") { Task { await login.start(folder: folder) } }
                        .disabled(login.email.isEmpty || login.password.isEmpty)
                }
                checkRow
                if case .done(let text) = login.phase { Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if case .failed(let text) = login.phase { Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
    }

    @ViewBuilder
    private var polarLoginForm: some View {
        let stored = PolarAccount.load()
        VStack(alignment: .leading, spacing: 10) {
            if stored?.hasToken == true {
                Label("Signed in (token present)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            Text("1. Sign in at admin.polaraccesslink.com with your Polar account and create a client (free). Name: e.g. “Pace Lab”. Enter exactly this as the redirect URL:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(PolarAccount.redirectURL).font(.callout.monospaced()).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PolarAccount.redirectURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Link("Open admin.polaraccesslink.com", destination: PolarAccount.adminURL)
            }
            Text("2. Enter the client ID and secret here — they stay on this Mac.")
                .font(.callout)
            switch polar.phase {
            case .waiting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the approval in the browser …")
                    Button("Cancel") { polar.cancel() }
                }
            default:
                HStack {
                    TextField("Client ID", text: $polar.clientID,
                              prompt: Text(stored?.clientID.map { String(localized: "stored: \($0.prefix(8))…") } ?? String(localized: "Client ID")))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    SecureField("Client secret", text: $polar.clientSecret,
                                prompt: Text(stored?.clientID != nil ? String(localized: "stored") : String(localized: "Client secret")))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                Button(stored?.hasToken == true ? String(localized: "Sign in to Polar again …") : String(localized: "Sign in to Polar …")) {
                    Task { await polar.start(folder: folder); await refresh() }
                }
                .disabled(stored?.clientID == nil && (polar.clientID.trimmingCharacters(in: .whitespaces).isEmpty
                                                      || polar.clientSecret.trimmingCharacters(in: .whitespaces).isEmpty))
                Text("3. Polar opens in the browser: allow access. Polar only passes on training sessions synced after this — runs from before don’t appear.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            checkRow
            if case .done(let text) = polar.phase { Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if case .failed(let text) = polar.phase { Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private var checkRow: some View {
        HStack {
            Button("Check connection") { checkWatch() }
            if let watchCheck {
                Label(watchCheck.text, systemImage: watchCheck.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(watchCheck.ok ? Color.green : Color.orange).font(.callout).lineLimit(2)
            }
        }
    }

    private var watchReady: Bool {
        switch model.watch {
        case .none: true
        case .garmin: serverConfigured != nil && WatchSetup.garmin.hasToken
        case .polar: serverConfigured != nil && WatchSetup.polar.hasToken
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
        serverConfigured = WatchServerConfig.load(from: folder, watch: model.watch).map { config in
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

    private func install(_ setup: WatchSetup) {
        installing = String(localized: "Starting …")
        installError = nil
        let folder = self.folder
        let tracker = installProgress
        Task {
            let watch = Task {
                while !Task.isCancelled {
                    if let text = tracker.text { installing = text }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            do {
                try await Task.detached {
                    try setup.install { step in Task { @MainActor in tracker.text = step } }
                    try setup.writeConfig(folder: folder)
                }.value
            } catch {
                installError = error.localizedDescription
            }
            watch.cancel()
            installing = nil
            tracker.text = nil
            await refresh()
        }
    }

    private func checkWatch() {
        watchCheck = nil
        let folder = self.folder
        let watch = model.watch
        Task {
            watchCheck = await WatchCheck.run(watch, folder: folder)
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
