import WidgetKit
import SwiftUI

struct TrainingEntry: TimelineEntry {
    let date: Date
    let snapshot: TrainingSnapshot?
    var errorMessage: String? = nil
    /// Profile shown; nil as long as the app hasn't passed on any profiles yet.
    var profile: WidgetProfiles.Entry? = nil
    /// Several profiles: the widget shows whose training it is.
    var showsProfile = false

    /// Link into the app, e.g. "session/<id>" — to the widget's profile.
    func url(_ path: String) -> URL? {
        var components = URLComponents(string: "pacelab://\(path)")
        if let profile { components?.queryItems = [URLQueryItem(name: "profile", value: profile.id)] }
        return components?.url
    }
}

/// One entry now plus one per midnight of the next week, so that
/// "current week" and "starts in X days" keep running even without new data.
/// The app triggers new data with `reloadAllTimelines()`.
struct TrainingProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TrainingEntry {
        Self.entry(at: .now, profile: nil)
    }

    func snapshot(for configuration: SelectProfileIntent, in context: Context) async -> TrainingEntry {
        Self.entry(at: .now, profile: configuration.profile?.id)
    }

    func timeline(for configuration: SelectProfileIntent, in context: Context) async -> Timeline<TrainingEntry> {
        let first = Self.entry(at: .now, profile: configuration.profile?.id)
        let cal = DateUtil.calendar
        let today = cal.startOfDay(for: .now)
        var entries = [first]
        for offset in 1...7 {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            entries.append(TrainingEntry(date: day, snapshot: first.snapshot, errorMessage: first.errorMessage,
                                         profile: first.profile, showsProfile: first.showsProfile))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// `profile`: chosen in the widget's configuration; nil = the profile that is active in the app.
    private static func entry(at date: Date, profile: String?) -> TrainingEntry {
        let profiles = SnapshotStore.loadProfiles()
        // A deleted profile: back to the active one.
        let id = profile.flatMap { profiles?.entry($0) != nil ? $0 : nil } ?? profiles?.active
        let shown = id.flatMap { profiles?.entry($0) }
        let several = (profiles?.profiles.count ?? 0) > 1
        do {
            return TrainingEntry(date: date, snapshot: try SnapshotStore.load(profile: id), profile: shown, showsProfile: several)
        } catch {
            return TrainingEntry(date: date, snapshot: nil, errorMessage: error.localizedDescription, profile: shown, showsProfile: several)
        }
    }
}

// MARK: - Gemeinsame Widget-Bausteine

/// Small round badge with the profile's initial — only when there are several profiles.
struct ProfileBadge: View {
    let entry: TrainingEntry

    var body: some View {
        if entry.showsProfile, let profile = entry.profile {
            Text(profile.initial)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brand)
                .frame(width: 16, height: 16)
                .background(Color.brand.opacity(0.18), in: Circle())
                .accessibilityLabel(profile.name)
        }
    }
}

struct WidgetMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.brand)
            Text(text)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetBar: View {
    let value: Double
    var color: Color = .brand

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}

extension View {
    /// Subtle gradient in the color of the session or the rating.
    func widgetBackground(tint: Color = .brand) -> some View {
        containerBackground(for: .widget) {
            LinearGradient(colors: [tint.opacity(0.22), Color.pageBackground],
                           startPoint: .topLeading, endPoint: .bottom)
        }
    }
}
