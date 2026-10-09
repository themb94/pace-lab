import SwiftUI

@main
struct PaceLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Pace Lab", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onOpenURL { model.open($0) }
                #if DEBUG
                .modifier(DebugSnapshotHook(model: model))
                #endif
        }
        .defaultSize(width: 1260, height: 830)
        // Widget links (pacelab://…) open this window, even if it was closed.
        .handlesExternalEvents(matching: ["pacelab"])
        .commands {
            CommandGroup(after: .appSettings) {
                SetupCommand()
            }
            CommandGroup(replacing: .newItem) {
                Button("Load runs (\(SyncSettings.source.shortLabel))") { model.syncRuns() }
                    .keyboardShortcut("r")
                    .disabled(model.sync.isRunning || model.coach.isRunning || model.snapshot == nil)
                Button("Reload files") { model.reload(force: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Coach") {
                Button("Plan …") { model.requestPlan(.week) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.coach.isRunning || model.snapshot == nil)
                Divider()
                ForEach(CoachAction.all) { action in
                    Button(action.title) { model.startCoach(action) }
                        .disabled(model.coach.isRunning || !model.coach.activeEngine.kind.isAgent
                                  || (action.needsConversation && model.coach.current == nil))
                }
                Divider()
                Button("New conversation") {
                    model.section = .coach
                    model.coach.newConversation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.coach.isRunning)
                Button("Cancel") { model.coach.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.coach.isRunning)
            }
        }

        Window("Setup", id: "setup") {
            SetupView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 820)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.coach.isRunning ? "figure.run.circle.fill" : "figure.run")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // If a coach CLI exits right away, writing the request must not terminate the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Window closed → the app keeps running in the menu bar and keeps the widgets up to date.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// "Setup …" in the app menu.
private struct SetupCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Setup …") { openWindow(id: "setup") }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Training") {
                    Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
                        .tag(SidebarItem.overview)
                    Label("Plan", systemImage: "calendar")
                        .tag(SidebarItem.plan)
                    Label("Runs", systemImage: "figure.run")
                        .tag(SidebarItem.runs)
                }
                Section("Assistant") {
                    Label("Coach", systemImage: "sparkles")
                        .badge(model.coach.isRunning ? Text("running") : nil)
                        .tag(SidebarItem.coach)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            Group {
                switch model.section ?? .overview {
                case .overview: OverviewView()
                case .plan: PlanView()
                case .runs: RunsView()
                case .coach: CoachView()
                case .history: HistoryView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SyncButton()
                }
            }
            .overlay(alignment: .top) { ToastView() }
        }
        .task {
            // First launch: training folder is missing → show the setup.
            if !TrainingFolderSetup.isReady(model.folder.url) { openWindow(id: "setup") }
        }
        .sheet(item: $model.planRequest) { request in
            PlanRequestSheet(request: request)
        }
        .sheet(item: Binding(
            get: { model.garminUploadWeek.map(UploadWeek.init) },
            set: { model.garminUploadWeek = $0?.week })) { item in
            GarminUploadSheet(week: item.week)
        }
    }
}

private struct UploadWeek: Identifiable {
    let week: Int
    var id: Int { week }
}

/// "Load runs" — in every section at the top left next to the title.
private struct SyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        if sync.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(sync.step ?? String(localized: "Loading …"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                Button {
                    sync.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
        } else {
            Button {
                model.syncRuns()
            } label: {
                Label("Load runs", systemImage: "arrow.down.circle")
            }
            .help(String(localized: "Fetch new runs from \(SyncSettings.source.shortLabel) (⌘R)")
                  + (sync.lastSync.map { String(localized: " — updated \($0.formatted(.relative(presentation: .named).locale(Fmt.locale)))") } ?? ""))
            .disabled(model.coach.isRunning || model.snapshot == nil)
        }
    }
}

/// Short feedback at the top of the window, disappears after a few seconds.
private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol)
                    .foregroundStyle(toast.isError ? Color.orange : Color.green)
                Text(toast.message)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = toast.action {
                    Button(actionTitle(action)) { model.perform(action) }
                        .controlSize(.small)
                }
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .frame(maxWidth: 620)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.isError ? 12 : 6))
                withAnimation { if model.toast?.id == toast.id { model.toast = nil } }
            }
        }
    }

    private func actionTitle(_ action: Toast.Action) -> String {
        switch action {
        case .showRuns: String(localized: "Show")
        case .showPlan: String(localized: "Go to plan")
        case .showHistory: String(localized: "History")
        }
    }
}

/// Data status at the bottom of the sidebar, next to the way to Settings.
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            status
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(12)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let snapshot = model.snapshot {
                Text(snapshot.statusLine(on: .now))
                    .font(.caption.weight(.semibold))
            }
            if let synced = model.sync.lastSync {
                Text("Runs loaded: \(synced.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let loaded = model.lastLoaded {
                Text("Files: \(loaded.formatted(.dateTime.hour().minute().second().locale(Fmt.locale)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(model.folder.url.path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
