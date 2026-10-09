import Foundation

/// The watch a profile trains with — chosen in the setup, changeable in Settings → Runs
/// (e.g. after buying a new one). Decides which server loads runs and what "for the watch" means.
enum WatchKind: String, CaseIterable, Identifiable, Sendable {
    case garmin, polar, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .garmin: "Garmin"
        case .polar: "Polar"
        case .none: String(localized: "Other / none")
        }
    }

    /// Name of the server in the training folder's .mcp.json.
    var serverName: String? {
        switch self {
        case .garmin: "garmin-workouts"
        case .polar: "polar"
        case .none: nil
        }
    }

    /// Tool that checks the sign-in.
    var statusTool: String {
        self == .polar ? "polar_status" : "garmin_status"
    }

    var runSource: RunSource? {
        switch self {
        case .garmin: .garmin
        case .polar: .polar
        case .none: nil
        }
    }

    /// Only Garmin lets other apps put workouts on the watch; Polar gets the week as phases to enter by hand.
    var canUpload: Bool { self == .garmin }

    /// The coach's read tools for this watch (Claude Code tool names).
    var readTools: [String] {
        switch self {
        case .garmin: ClaudeCodeRunner.garminReadTools
        case .polar: ["mcp__polar__polar_status", "mcp__polar__list_activities",
                      "mcp__polar__get_activity_data", "mcp__polar__preview_plan"]
        case .none: []
        }
    }
}

/// The active profile's watch (UserDefaults). Profiles from before this setting use Garmin.
enum WatchSettings {
    static let key = "watch"

    static var current: WatchKind {
        AppSettings.defaults.string(forKey: key).flatMap(WatchKind.init(rawValue:)) ?? .garmin
    }

    static func set(_ watch: WatchKind) {
        AppSettings.defaults.set(watch.rawValue, forKey: key)
    }
}
