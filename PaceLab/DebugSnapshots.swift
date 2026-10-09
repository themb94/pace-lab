#if DEBUG
import AppKit

/// Development/testing only: with `-debugSnapshots <folder>` the app saves images of its views.
/// Optional: `-debugSettings YES` (Settings), `-debugSync YES` (Load runs), `-debugPlanSheet YES`
/// (planning form), `-debugEngine "<name>"` + `-debugCoachPrompt "<question>"` asks the coach a real
/// question, `-debugDark YES`, `-debugCreateFolder YES` (creates the empty project folder from the template), `-debugTour <folder>` (walkthrough with window captures), `-debugSupportDirectory <folder>` (separate conversations/model lists, profiles, no widget data), `-debugQuit YES` quits the app afterwards. Language: `-AppleLanguages "(en)"` or `"(de)"`. With `-projectPath <folder>` against a copy (an empty folder shows the setup).
/// Profiles (only together with `-debugSupportDirectory`): `-debugProfile <name>` creates a test profile with the training
/// folder `-debugProfileFolder <folder>`, switches to it and captures the profile views; everything after that runs in it.
/// `-debugGarminConfig YES` registers the Garmin server in its folder, `-debugWatch polar` sets its watch (and registers the
/// Polar server; `-debugInstallWatch YES` installs it, `-debugPolarLogin <client id>` signs in against a fake Polar given by
/// POLAR_API_BASE/POLAR_AUTH_URL/POLAR_TOKEN_URL in the environment), `-debugSwitchBack YES` returns to the main profile at the end
/// (and `-debugDeleteProfile YES` deletes the test profile after that).
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel, openSettings: () -> Void, openWindow: (String) -> Void) async {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "debugSnapshots") else { return }
        let dir = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if defaults.bool(forKey: "debugDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }

        if let name = defaults.string(forKey: "debugProfile"), defaults.string(forKey: "debugSupportDirectory") != nil {
            await profiles(name: name, model: model, dir: dir, openSettings: openSettings, openWindow: openWindow)
        }

        // `-debugCreateFolder YES`: creates the (empty) project folder from the template, as the setup does.
        if defaults.bool(forKey: "debugCreateFolder"), !TrainingFolderSetup.isReady(model.folder.url) {
            try? await TrainingFolderSetup.create(at: model.folder.url)
            model.reload(force: true)
        }
        for _ in 0..<50 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
        mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }

        // `-debugTour <folder>`: walks through the sections in order and saves images of the real window.
        if let tour = defaults.string(forKey: "debugTour"), let window = mainWindow {
            await DebugTour.run(model: model, window: window, openSettings: openSettings,
                                dir: URL(filePath: tour, directoryHint: .isDirectory))
            NSApp.terminate(nil)
            return
        }

        func shot(_ name: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            capture(name, to: dir)
        }

        model.section = .overview
        await shot("1-overview")
        if let setup = NSApp.windows.first(where: { $0.isVisible && ["Einrichtung", "Setup"].contains($0.title) }) {
            try? await Task.sleep(for: .seconds(3))
            capture(setup, "0-setup", to: dir)
        }
        model.selectedSessionID = model.snapshot?.nextSession?.id
        model.showSessionInspector = true
        model.section = .plan
        await shot("2-plan")
        if model.draft != nil {
            model.showDraft = true
            await shot("2b-draft")
            model.showDraft = false
        }
        model.selectedRunID = model.snapshot?.runs.first { ($0.splits?.count ?? 0) > 10 }?.id
        model.section = .runs
        await shot("3-runs")
        if let fresh = model.snapshot?.runs.first(where: { !$0.isAnalyzed }) {
            model.selectedRunID = fresh.id
            await shot("3b-run-new")
        }
        model.section = .coach
        await shot("4-coach")
        model.section = .history
        await shot("8-history")

        if defaults.bool(forKey: "debugSync") {
            model.section = .runs
            model.syncRuns()
            await shot("9a-sync-running")
            for _ in 0..<120 where model.sync.isRunning { try? await Task.sleep(for: .seconds(1)) }
            await shot("9b-sync-done")
            model.section = .history
            await shot("9c-history-after-sync")
        }

        if defaults.bool(forKey: "debugPlanSheet") {
            model.section = .plan
            model.requestPlan(.week, week: 2)
            try? await Task.sleep(for: .seconds(2))
            if let sheet = mainWindow?.attachedSheet { capture(sheet, "10-plan-sheet", to: dir) }
            model.planRequest = nil
            try? await Task.sleep(for: .seconds(1))
            model.watchWeek = 1
            try? await Task.sleep(for: .seconds(8))
            if let sheet = mainWindow?.attachedSheet { capture(sheet, "11-garmin-sheet", to: dir) }
            model.watchWeek = nil
            try? await Task.sleep(for: .seconds(1))
        }

        if defaults.bool(forKey: "debugSettings") {
            for tab in ["general", "runs", "coach"] {
                defaults.set(tab, forKey: "settingsTab")
                openSettings()
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeKey }) {
                    capture(window, "7-settings-\(tab)", to: dir)
                    window.close()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if let name = defaults.string(forKey: "debugEngine"),
           let engine = model.coach.engines.first(where: { $0.name == name }) {
            model.coach.selectEngine(engine.id)
            await shot("4b-coach-engine")
        }

        if let prompt = defaults.string(forKey: "debugCoachPrompt") {
            model.section = .coach
            model.coach.newConversation()
            model.coach.draft = prompt
            model.coach.sendDraft(in: model.folder.url)
            await shot("5-coach-running")
            for _ in 0..<300 where model.coach.isRunning { try? await Task.sleep(for: .seconds(1)) }
            await shot("6-coach-done")
        }

        if let details = defaults.string(forKey: "debugPlan") {
            model.coach.newConversation()
            var request = PlanRequest(kind: .week, snapshot: model.snapshot, week: 2)
            request.details = details
            model.submit(request)
            await shot("12a-plan-running")
            for _ in 0..<900 where model.coach.isRunning { try? await Task.sleep(for: .seconds(1)) }
            await shot("12b-plan-done")
            model.selectedSessionID = model.snapshot?.sessions(inWeek: 2).first?.id
            model.section = .plan
            await shot("12c-plan-week2")
            if defaults.bool(forKey: "debugUndo"), let turn = model.coach.current?.turns.last {
                _ = await model.undo(turn)
                model.section = .coach
                await shot("12d-undone")
            }
        }

        if defaults.bool(forKey: "debugSwitchBack"), let main = model.profiles.profiles.first(where: \.isMain) {
            model.switchProfile(to: main.id)
            for _ in 0..<50 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
            mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title != "Setup" && $0.title != "Einrichtung" }
            try? await Task.sleep(for: .seconds(1.5))
            captureOnScreen("p9-back-to-main", to: dir)
            if defaults.bool(forKey: "debugDeleteProfile"), let name = defaults.string(forKey: "debugProfile"),
               let test = model.profiles.profiles.first(where: { $0.name == name && !$0.isMain }) {
                model.deleteProfile(test.id)
                print("PROFILE deleted \(test.id) remaining=\(model.profiles.profiles.map(\.displayName))")
                try? await Task.sleep(for: .seconds(8))   // sign-out and cleanup run in the background
            }
        }

        if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
    }

    /// Test profile: create (or reuse), switch, capture main window, setup, settings and the form for a new profile.
    private static func profiles(name: String, model: AppModel, dir: URL, openSettings: () -> Void, openWindow: (String) -> Void) async {
        let defaults = UserDefaults.standard
        let profile = model.profiles.profiles.first { $0.name == name } ?? model.profiles.create(named: name)
        if let folder = defaults.string(forKey: "debugProfileFolder") {
            profile.defaults.set(folder, forKey: AppSettings.Key.projectPath)
        }
        model.switchProfile(to: profile.id)
        print("PROFILE active=\(model.profile.displayName) folder=\(model.folder.url.path) data=\(model.profile.dataDirectory.path)")
        print("PROFILE env=\(model.profile.cliEnvironment)")
        if defaults.bool(forKey: "debugCreateFolder"), !TrainingFolderSetup.isReady(model.folder.url) {
            try? await TrainingFolderSetup.create(at: model.folder.url)
            model.folderChanged()
        }
        if defaults.bool(forKey: "debugGarminConfig") {
            try? WatchSetup.garmin.writeConfig(folder: model.folder.url)
        }
        // `-debugWatch polar|garmin|none`: the test profile's watch; for Polar also registers the server.
        if let value = defaults.string(forKey: "debugWatch"), let watch = WatchKind(rawValue: value) {
            model.setWatch(watch)
            if watch == .polar { try? WatchSetup.polar.writeConfig(folder: model.folder.url) }
            // `-debugInstallWatch YES`: installs the server like the setup does (Python environment in the support directory).
            if defaults.bool(forKey: "debugInstallWatch"), let setup = WatchSetup.for(watch) {
                let folder = model.folder.url
                do {
                    try await Task.detached {
                        try setup.install { print("WATCH install: \($0)") }
                        try setup.writeConfig(folder: folder)
                    }.value
                    print("WATCH installed \(setup.directory.path)")
                } catch {
                    print("WATCH install failed: \(error.localizedDescription)")
                }
            }
            // `-debugPolarLogin <client id>`: the sign-in against a fake Polar (POLAR_AUTH_URL etc. in the environment);
            // the approval page is requested directly instead of opening the browser.
            if watch == .polar, let client = defaults.string(forKey: "debugPolarLogin") {
                let login = PolarLogin()
                login.clientID = client
                login.clientSecret = "debug-secret"
                login.openURL = { url in Task.detached { _ = try? await URLSession.shared.data(from: url) } }
                await login.start(folder: model.folder.url)
                print("POLAR login: \(login.phase)")
                print("POLAR check: \(await WatchCheck.run(.polar, folder: model.folder.url))")
            }
        }
        for _ in 0..<50 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1.5))
        mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title != "Setup" && $0.title != "Einrichtung" }
        captureOnScreen("p1-profile-overview", to: dir)

        openWindow("setup")
        try? await Task.sleep(for: .seconds(6))   // CLI and Strava checks
        if let setup = NSApp.windows.first(where: { $0.isVisible && ["Einrichtung", "Setup"].contains($0.title) }) {
            capture(setup, "p2-profile-setup", to: dir)
            // Further down: watch and Strava.
            if let scroll = firstScrollView(in: setup.contentView), let document = scroll.documentView {
                let y = max(0, document.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? y * 0.62 : y * 0.38))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .seconds(1))
                capture(setup, "p2b-profile-setup-watch", to: dir)
            }
            setup.close()
        }

        for tab in [SettingsTab.profiles, SettingsTab.general] {
            defaults.set(tab, forKey: SettingsTab.key)
            openSettings()
            try? await Task.sleep(for: .seconds(2))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeKey }) {
                capture(window, "p3-settings-\(tab)", to: dir)
                window.close()
            }
            try? await Task.sleep(for: .seconds(1))
        }

        model.showNewProfile = true
        try? await Task.sleep(for: .seconds(1.5))
        if let sheet = mainWindow?.attachedSheet { capture(sheet, "p4-new-profile", to: dir) }
        model.showNewProfile = false
        try? await Task.sleep(for: .seconds(1))
    }

    private static var mainWindow: NSWindow?

    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    /// The app's own window as it looks on screen (including the sidebar with vibrancy). Own windows
    /// can be captured without screen recording permission; the function only exists as a symbol now.
    static func captureWindowImage(_ window: NSWindow) -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// The main window as it is on screen — with the sidebar's vibrancy (the profile menu sits there).
    private static func captureOnScreen(_ name: String, to dir: URL) {
        guard let window = mainWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard let image = captureWindowImage(window),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            capture(window, name, to: dir)
            return
        }
        try? data.write(to: dir.appending(path: "\(name).png"))
    }

    private static func capture(_ name: String, to dir: URL) {
        guard let window = mainWindow else { return }
        capture(window, name, to: dir)
    }

    private static func capture(_ window: NSWindow, _ name: String, to dir: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}

import SwiftUI

/// Attaches the snapshot routine to the main window (needs `openSettings` and `openWindow` from the environment).
struct DebugSnapshotHook: ViewModifier {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            await DebugSnapshots.runIfRequested(model: model, openSettings: { openSettings() }, openWindow: { openWindow(id: $0) })
        }
    }
}
#endif
