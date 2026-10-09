import Foundation
import Observation

/// Settings for "Load runs" (UserDefaults).
enum SyncSettings {
    enum Key {
        static let source = "runSource"
        static let stravaModel = "syncStravaModel"
        static let autoAssign = "syncAutoAssign"
        static let lastSync = "lastRunSync"
    }

    static var source: RunSource {
        UserDefaults.standard.string(forKey: Key.source).flatMap(RunSource.init(rawValue:)) ?? .garmin
    }

    /// A small, fast model is enough — it only calls two tools.
    static let defaultStravaModel = "haiku"

    static var stravaModel: String {
        UserDefaults.standard.string(forKey: Key.stravaModel) ?? defaultStravaModel
    }

    static var autoAssign: Bool {
        UserDefaults.standard.object(forKey: Key.autoAssign) as? Bool ?? true
    }

    /// Where the search starts: three days before the newest stored run (stragglers),
    /// at most 60 days back.
    static func since(_ snapshot: TrainingSnapshot, today: Date = .now) -> String {
        let cal = DateUtil.calendar
        let floor = cal.date(byAdding: .day, value: -60, to: today)!
        let newest = snapshot.runs.compactMap(\.day).max() ?? cal.date(byAdding: .day, value: -14, to: today)!
        let start = max(floor, cal.date(byAdding: .day, value: -3, to: newest)!)
        return DateUtil.iso(start)
    }
}

/// Fetches new runs from Garmin or Strava and enters them in analysis.json.
@MainActor
@Observable
final class RunSyncModel {
    enum State: Equatable {
        case idle
        case running(String)
        case finished(Summary)
        case failed(String)
    }

    struct Summary: Equatable {
        let message: String
        let date: Date
        /// IDs of the new runs (like `Run.id`) — for display.
        let runIDs: [String]
    }

    private(set) var state: State = .idle
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: SyncSettings.Key.lastSync) as? Date
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var step: String? {
        if case .running(let step) = state { return step }
        return nil
    }

    func dismissResult() {
        if !isRunning { state = .idle }
    }

    func cancel() {
        task?.cancel()
    }

    /// `claudeCommand`: program of the Claude Code engine (for Strava). `onFinish(changed)` is always called,
    /// `changed` = runs were entered.
    func start(folder: ProjectFolder, snapshot: TrainingSnapshot, history: ProjectHistory?, claudeCommand: String,
               onFinish: @escaping @MainActor (Bool) -> Void) {
        guard !isRunning else { return }
        let source = SyncSettings.source
        let since = SyncSettings.since(snapshot)
        let known = KnownRuns(snapshot.runs)
        let knownStrava = snapshot.runs.filter { $0.date >= since }.compactMap(\.stravaId)
        let model = SyncSettings.stravaModel
        let autoAssign = SyncSettings.autoAssign
        state = .running(String(localized: "\(source.shortLabel): starting …"))

        let progress: SyncProgress = { [weak self] step in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.state = .running(step)
            }
        }

        task = Task {
            do {
                var runs: [ImportedRun]
                switch source {
                case .garmin:
                    runs = try await GarminRunSource(folder: folder.url).fetch(since: since, known: known, progress: progress)
                case .strava:
                    runs = try await StravaViaClaudeSource(folder: folder.url, command: claudeCommand, model: model)
                        .fetch(since: since, knownIDs: knownStrava, known: known, progress: progress)
                }
                try Task.checkCancellation()

                // Immediately assign unambiguous workout runs to their session and check them off.
                var ticks: [(session: PlannedSession, date: String)] = []
                if autoAssign {
                    for i in runs.indices {
                        guard let session = SessionMatcher.exactMatch(name: runs[i].name, in: snapshot),
                              snapshot.linkedRun(for: session) == nil,
                              !runs.contains(where: { $0.sessionID == session.id }) else { continue }
                        runs[i].assign(session.id)
                        if !snapshot.isDone(session) { ticks.append((session, runs[i].date)) }
                    }
                }

                let found = runs
                let marks = ticks.map { (id: $0.session.id, date: $0.date) }
                if !found.isEmpty {
                    try await Task.detached {
                        try AnalysisWriter.insert(found, in: folder)
                        for mark in marks {
                            try folder.setCompleted(true, sessionID: mark.id, on: DateUtil.day(fromISO: mark.date) ?? .now)
                        }
                    }.value
                    _ = try? await history?.commit(Self.commitMessage(found, source: source, snapshot: snapshot),
                                               paths: [TrainingFiles.analysis, TrainingFiles.completed])
                }

                let now = Date.now
                lastSync = now
                UserDefaults.standard.set(now, forKey: SyncSettings.Key.lastSync)
                state = .finished(Summary(message: Self.summary(found, ticks: ticks.count, source: source),
                                          date: now, runIDs: found.map(\.activityID)))
                task = nil
                onFinish(!found.isEmpty)
            } catch is CancellationError {
                state = .idle
                task = nil
                onFinish(false)
            } catch {
                state = .failed(error.localizedDescription)
                task = nil
                onFinish(false)
            }
        }
    }

    private static func summary(_ runs: [ImportedRun], ticks: Int, source: RunSource) -> String {
        switch runs.count {
        case 0: return String(localized: "No new runs from \(source.shortLabel).")
        case 1: return String(localized: "1 new run from \(source.shortLabel)") + (ticks > 0 ? String(localized: " · session ticked off") : "")
        default: return String(localized: "\(runs.count) new runs from \(source.shortLabel)") + (ticks > 0 ? String(localized: " · \(ticks) sessions ticked off") : "")
        }
    }

    private static func commitMessage(_ runs: [ImportedRun], source: RunSource, snapshot: TrainingSnapshot) -> String {
        let lines = runs.sorted { $0.date < $1.date }.map { run -> String in
            let session = run.sessionID.flatMap(snapshot.session(id:))
            return "- \(run.shortDescription)" + (session.map { " → W\($0.week) \($0.kind.label) ✓" } ?? "")
        }
        let title = runs.count == 1 ? String(localized: "Run loaded (\(source.shortLabel)): \(runs[0].shortDescription)")
                                    : String(localized: "\(runs.count) runs loaded (\(source.shortLabel))")
        return title + "\n\n" + lines.joined(separator: "\n")
    }
}
