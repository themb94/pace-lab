import Foundation

/// The training data as it sits in the training folder.
enum TrainingFiles {
    static let plan = "plan.json"
    static let analysis = "analysis.json"
    static let completed = "completed.json"
    static let all = [plan, analysis, completed]

    /// Builds a snapshot from the raw files. `completed` may be missing.
    static func decode(plan: Data, analysis: Data, completed: Data?) throws -> TrainingSnapshot {
        let decodedPlan = try decode(TrainingPlan.self, from: plan, file: TrainingFiles.plan, decoder: .snakeCase)
        let decodedAnalysis = try decode(AnalysisFile.self, from: analysis, file: TrainingFiles.analysis, decoder: .snakeCase)
        let marks = try completed.map {
            try decode(CompletionFile.self, from: $0, file: TrainingFiles.completed, decoder: JSONDecoder()).marks
        } ?? [:]
        return TrainingSnapshot(plan: decodedPlan, analysis: decodedAnalysis, completed: marks)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String, decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw StoreError.invalidFile(file, error)
        }
    }
}

/// The profiles as the widgets see them: names for the configuration and which one is active in the app.
struct WidgetProfiles: Codable, Sendable {
    struct Entry: Codable, Sendable, Hashable {
        let id: String
        let name: String
        let initial: String
    }

    var active: String
    var profiles: [Entry]

    func entry(_ id: String) -> Entry? { profiles.first { $0.id == id } }
}

/// Copy of the training data in the app group container — one folder per profile. The app writes it on
/// every change, the (sandboxed) widgets read it — they can't reach the training folders.
enum SnapshotStore {
    /// Team prefix instead of "group.": valid on the Mac without a provisioning profile. Comes from the build
    /// (Config/Signing.xcconfig → Info.plist), so that every installation has its own identifier.
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "PaceLabAppGroup") as? String ?? ""

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Trainingsdaten", directoryHint: .isDirectory)
    }

    private static func directory(profile: String) -> URL? {
        directory?.appending(path: profile, directoryHint: .isDirectory)
    }

    private static var profilesURL: URL? { directory?.appending(path: "profiles.json") }

    /// For the widgets: the data of a profile (nil = the profile that is active in the app).
    static func load(profile: String?) throws -> TrainingSnapshot {
        guard directory != nil else { throw StoreError.noAppGroup }
        guard let id = profile ?? loadProfiles()?.active, let folder = directory(profile: id) else {
            throw StoreError.notSyncedYet
        }
        func data(_ name: String) -> Data? { try? Data(contentsOf: folder.appending(path: name)) }
        guard let plan = data(TrainingFiles.plan), let analysis = data(TrainingFiles.analysis) else {
            throw StoreError.notSyncedYet
        }
        return try TrainingFiles.decode(plan: plan, analysis: analysis, completed: data(TrainingFiles.completed))
    }

    /// For the app: overwrites a profile's copy with the current state of its training folder.
    static func save(_ files: [String: Data], profile: String) throws {
        guard let folder = directory(profile: profile) else { throw StoreError.noAppGroup }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in TrainingFiles.all {
            let url = folder.appending(path: name)
            if let data = files[name] {
                try data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func loadProfiles() -> WidgetProfiles? {
        guard let url = profilesURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetProfiles.self, from: data)
    }

    static func saveProfiles(_ profiles: WidgetProfiles) throws {
        guard let directory, let url = profilesURL else { throw StoreError.noAppGroup }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
        // Copies from before profiles existed (directly in the folder).
        for name in TrainingFiles.all { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    static func removeProfile(_ id: String) {
        guard let folder = directory(profile: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

enum StoreError: LocalizedError {
    case missingFile(String)
    case invalidFile(String, any Error)
    case noAppGroup
    case notSyncedYet

    var errorDescription: String? {
        switch self {
        case .missingFile(let name):
            String(localized: "\(name) is missing from the project folder.")
        case .invalidFile(let name, let error):
            String(localized: "\(name) could not be read: \(error.localizedDescription)")
        case .noAppGroup:
            String(localized: "The shared app group container is not available.")
        case .notSyncedYet:
            String(localized: "No data yet — open Pace Lab once.")
        }
    }
}
