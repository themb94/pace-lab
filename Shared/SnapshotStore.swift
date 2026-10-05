import Foundation

/// Die Trainingsdaten, wie sie im Trainingsordner liegen.
enum TrainingFiles {
    static let plan = "plan.json"
    static let analysis = "analysis.json"
    static let completed = "completed.json"
    static let all = [plan, analysis, completed]

    /// Baut aus den Roh-Dateien einen Snapshot. `completed` darf fehlen.
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

/// Kopie der Trainingsdaten im App-Group-Container. Die App schreibt sie bei jeder
/// Änderung, die (sandboxed) Widgets lesen sie — an den Projektordner kommen sie nicht heran.
enum SnapshotStore {
    /// Team-Präfix statt "group.": auf dem Mac ohne Provisioning-Profil gültig. Kommt aus dem Build
    /// (Config/Signing.xcconfig → Info.plist), damit jede Installation ihre eigene Kennung hat.
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "PaceLabAppGroup") as? String ?? ""

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Trainingsdaten", directoryHint: .isDirectory)
    }

    /// Für die Widgets.
    static func load() throws -> TrainingSnapshot {
        guard let directory else { throw StoreError.noAppGroup }
        func data(_ name: String) -> Data? { try? Data(contentsOf: directory.appending(path: name)) }
        guard let plan = data(TrainingFiles.plan), let analysis = data(TrainingFiles.analysis) else {
            throw StoreError.notSyncedYet
        }
        return try TrainingFiles.decode(plan: plan, analysis: analysis, completed: data(TrainingFiles.completed))
    }

    /// Für die App: überschreibt die Kopie mit dem aktuellen Stand des Projektordners.
    static func save(_ files: [String: Data]) throws {
        guard let directory else { throw StoreError.noAppGroup }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in TrainingFiles.all {
            let url = directory.appending(path: name)
            if let data = files[name] {
                try data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
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
