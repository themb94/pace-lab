import Foundation
import Observation
import Synchronization

/// A person who trains with Pace Lab. Profiles are completely separate from each other: each one has its
/// own training folder, settings, coach conversations and model lists, and its own sign-ins for Claude Code,
/// Codex, the watch (Garmin or Polar) and Strava — so every profile needs its own setup.
///
/// The main profile (the first one) keeps the app's original locations: UserDefaults.standard,
/// Application Support/Pace Lab, the CLIs' default configuration (~/.claude, ~/.codex) and ~/.garminconnect.
/// An existing setup keeps working unchanged. Every other profile lives in Application Support/Pace Lab/Profiles/<id>.
struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// How the coach addresses this person (empty = neutral; only the main profile may be unnamed).
    var name: String
    var isMain: Bool
    var createdAt: Date

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var displayName: String {
        if !trimmedName.isEmpty { return trimmedName }
        return isMain ? String(localized: "Main profile") : String(localized: "Unnamed profile")
    }

    /// First letter for the small badge (sidebar, widgets).
    var initial: String { String(displayName.prefix(1)).uppercased() }

    // MARK: Storage

    /// Conversations and model lists — and for further profiles also their sign-ins.
    var dataDirectory: URL {
        isMain ? AppSettings.supportDirectory
            : AppSettings.supportDirectory.appending(path: "Profiles/\(id.uuidString)", directoryHint: .isDirectory)
    }

    /// Settings (training folder, coach CLIs, run source); the main profile uses the app's standard defaults.
    var defaults: UserDefaults {
        #if DEBUG
        if isMain, let suite = Self.debugMainSuite { return ProfileDefaults.shared.defaults(for: suite) }
        #endif
        guard let suite = defaultsSuite else { return .standard }
        return ProfileDefaults.shared.defaults(for: suite)
    }

    #if DEBUG
    /// Development only: with `-debugSupportDirectory` the main profile's settings are kept apart from the real ones
    /// as well, and `-projectPath` only applies to the main profile — UserDefaults would otherwise apply a launch
    /// argument to every profile's settings.
    static let debugMainSuite: String? = {
        let standard = UserDefaults.standard
        guard standard.string(forKey: "debugSupportDirectory") != nil else { return nil }
        let suite = "\(Bundle.main.bundleIdentifier ?? "pacelab").debug"
        var arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let path = arguments.removeValue(forKey: AppSettings.Key.projectPath) {
            standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            UserDefaults(suiteName: suite)?.set(path, forKey: AppSettings.Key.projectPath)
        }
        return suite
    }()
    #endif

    var defaultsSuite: String? {
        isMain ? nil : "\(Bundle.main.bundleIdentifier ?? "pacelab").profile.\(id.uuidString)"
    }

    /// Own configuration of Claude Code (CLAUDE_CONFIG_DIR): sign-in, Strava, memory, sessions. nil = ~/.claude.
    var claudeConfigDirectory: URL? {
        isMain ? nil : dataDirectory.appending(path: "claude", directoryHint: .isDirectory)
    }

    /// Own configuration of Codex (CODEX_HOME). nil = ~/.codex.
    var codexHome: URL? {
        isMain ? nil : dataDirectory.appending(path: "codex", directoryHint: .isDirectory)
    }

    /// Where the Garmin server keeps this profile's token.
    var garminTokenStore: String {
        isMain ? "\(NSHomeDirectory())/.garminconnect" : dataDirectory.appending(path: "garminconnect").path
    }

    /// Where the Polar server keeps this profile's client and token (polar.json).
    var polarTokenStore: String {
        dataDirectory.appending(path: "polar").path
    }

    /// Claude Code's own files (memory, ~/.claude.json): with its own configuration everything is inside that folder.
    var claudeHome: URL { claudeConfigDirectory ?? URL(filePath: NSHomeDirectory()).appending(path: ".claude", directoryHint: .isDirectory) }
    var claudeStateFile: URL {
        claudeConfigDirectory?.appending(path: ".claude.json") ?? URL(filePath: NSHomeDirectory()).appending(path: ".claude.json")
    }
    var codexDirectory: URL { codexHome ?? URL(filePath: NSHomeDirectory()).appending(path: ".codex", directoryHint: .isDirectory) }

    /// Environment variables that point the CLIs to this profile's configuration.
    var cliEnvironment: [String: String] {
        var env: [String: String] = [:]
        if let claudeConfigDirectory { env["CLAUDE_CONFIG_DIR"] = claudeConfigDirectory.path }
        if let codexHome { env["CODEX_HOME"] = codexHome.path }
        return env
    }

    /// Training folder from the profile's settings.
    var projectPath: String {
        defaults.string(forKey: AppSettings.Key.projectPath) ?? AppSettings.defaultProjectPath
    }

    /// Creates the folders the CLIs expect (Codex refuses a CODEX_HOME that doesn't exist).
    func createDirectories() {
        for url in [dataDirectory, claudeConfigDirectory, codexHome].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func makeMain(name: String) -> Profile {
        Profile(id: UUID(), name: name, isMain: true, createdAt: .now)
    }
}

/// One UserDefaults object per profile suite, so that every view observes the same object.
final class ProfileDefaults: @unchecked Sendable {
    static let shared = ProfileDefaults()
    private let lock = NSLock()
    private var cache: [String: UserDefaults] = [:]

    func defaults(for suite: String) -> UserDefaults {
        lock.withLock {
            if let defaults = cache[suite] { return defaults }
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            cache[suite] = defaults
            return defaults
        }
    }

    /// Deletes a profile's settings for good (macOS may leave an empty file behind).
    func remove(_ suite: String) {
        lock.withLock {
            cache[suite]?.removePersistentDomain(forName: suite)
            cache[suite] = nil
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// The active profile, readable from any thread: settings, file locations and the CLIs' environment follow it.
enum ActiveProfile {
    private static let state = Mutex(Profile.makeMain(name: ""))

    static var current: Profile { state.withLock { $0 } }

    static func set(_ profile: Profile) {
        state.withLock { $0 = profile }
    }
}

// MARK: - Profile list

/// All profiles and which one is active (profiles.json in Application Support/Pace Lab).
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile]
    private(set) var activeID: UUID
    /// Called after every change (the widgets get the new list).
    var onChange: (@MainActor () -> Void)?

    private struct Stored: Codable {
        var active: UUID
        var profiles: [Profile]
    }

    init() {
        #if DEBUG
        _ = Profile.debugMainSuite   // before anything reads settings
        #endif
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.storeURL),
           let stored = try? decoder.decode(Stored.self, from: data), !stored.profiles.isEmpty {
            var list = stored.profiles
            // Exactly one main profile — it can't be deleted.
            if !list.contains(where: \.isMain) { list[0].isMain = true }
            profiles = list
            activeID = list.contains { $0.id == stored.active } ? stored.active : list[0].id
        } else {
            // First launch with profiles: the existing setup becomes the main profile.
            let main = Profile.makeMain(name: UserDefaults.standard.string(forKey: "athleteName") ?? "")
            profiles = [main]
            activeID = main.id
        }
        ActiveProfile.set(active)
        active.createDirectories()
        save()
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }

    var hasSeveral: Bool { profiles.count > 1 }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    /// Creates a profile with its own folder suggestion (e.g. ~/Documents/Pace Lab – Anna). It isn't activated yet.
    func create(named name: String) -> Profile {
        let profile = Profile(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), isMain: false, createdAt: .now)
        profile.createDirectories()
        profile.defaults.set(suggestedFolder(for: profile).path, forKey: AppSettings.Key.projectPath)
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].name != name else { return }
        profiles[i].name = name
        if id == activeID { ActiveProfile.set(profiles[i]) }
        save()
    }

    func activate(_ id: UUID) {
        guard let profile = profile(id) else { return }
        activeID = id
        ActiveProfile.set(profile)
        profile.createDirectories()
        save()
    }

    /// Removes a profile from the list together with its settings, conversations and sign-ins on this Mac.
    /// The training folder stays. Not for the main profile or the active one.
    func delete(_ id: UUID) {
        guard let profile = profile(id), !profile.isMain, id != activeID else { return }
        profiles.removeAll { $0.id == id }
        save()
        Task.detached(priority: .utility) {
            Self.signOut(profile)
            if let suite = profile.defaultsSuite { ProfileDefaults.shared.remove(suite) }
            try? FileManager.default.removeItem(at: profile.dataDirectory)
            SnapshotStore.removeProfile(profile.id.uuidString)
        }
    }

    /// Signs the profile's CLIs out, so that no login is left behind in the keychain.
    nonisolated private static func signOut(_ profile: Profile) {
        let env = profile.cliEnvironment
        guard !env.isEmpty else { return }
        if let claude = CLIResolver.find("claude") { _ = ProcessRunner.run(claude, ["auth", "logout"], environment: env) }
        if let codex = CLIResolver.find("codex") { _ = ProcessRunner.run(codex, ["logout"], environment: env) }
    }

    /// The profile that uses this training folder (each folder belongs to one profile only).
    func owner(ofFolder path: String) -> Profile? {
        let target = URL(filePath: path).standardizedFileURL.path
        return profiles.first { URL(filePath: $0.projectPath).standardizedFileURL.path == target }
    }

    /// "~/Documents/Pace Lab – Anna"; a number is added if another profile already uses the folder.
    private func suggestedFolder(for profile: Profile) -> URL {
        let documents = URL(filePath: NSHomeDirectory()).appending(path: "Documents", directoryHint: .isDirectory)
        let cleaned = profile.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = documents.appending(path: "Pace Lab – \(cleaned)", directoryHint: .isDirectory)
        var number = 2
        while owner(ofFolder: candidate.path) != nil {
            candidate = documents.appending(path: "Pace Lab – \(cleaned) \(number)", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }

    private static var storeURL: URL { AppSettings.supportDirectory.appending(path: "profiles.json") }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Stored(active: activeID, profiles: profiles)) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
        onChange?()
    }
}
