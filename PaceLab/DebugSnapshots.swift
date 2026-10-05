#if DEBUG
import AppKit

/// Nur für Entwicklung/Tests: Mit `-debugSnapshots <Ordner>` legt die App Bilder ihrer Ansichten ab.
/// Optional: `-debugSettings YES` (Einstellungen), `-debugSync YES` (Läufe laden), `-debugPlanSheet YES`
/// (Planungsformular), `-debugEngine "<Name>"` + `-debugCoachPrompt "<Frage>"` stellt dem Coach eine echte
/// Frage, `-debugDark YES`, `-debugCreateFolder YES` (legt den leeren Projektordner aus der Vorlage an), `-debugQuit YES` beendet die App danach. Sprache: `-AppleLanguages "(en)"` bzw. `"(de)"`. Mit `-projectPath <Ordner>` gegen eine Kopie (ein leerer Ordner zeigt die Einrichtung).
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel, openSettings: () -> Void) async {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "debugSnapshots") else { return }
        let dir = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if defaults.bool(forKey: "debugDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }

        // `-debugCreateFolder YES`: legt den (leeren) Projektordner aus der Vorlage an, wie die Einrichtung es tut.
        if defaults.bool(forKey: "debugCreateFolder"), !TrainingFolderSetup.isReady(model.folder.url) {
            try? await TrainingFolderSetup.create(at: model.folder.url)
            model.reload(force: true)
        }
        for _ in 0..<50 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
        mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }

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
            model.garminUploadWeek = 1
            try? await Task.sleep(for: .seconds(8))
            if let sheet = mainWindow?.attachedSheet { capture(sheet, "11-garmin-sheet", to: dir) }
            model.garminUploadWeek = nil
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

        if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
    }

    private static var mainWindow: NSWindow?

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

/// Hängt die Snapshot-Routine an das Hauptfenster (braucht `openSettings` aus der Umgebung).
struct DebugSnapshotHook: ViewModifier {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task { await DebugSnapshots.runIfRequested(model: model, openSettings: { openSettings() }) }
    }
}
#endif
