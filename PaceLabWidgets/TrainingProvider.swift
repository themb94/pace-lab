import WidgetKit
import SwiftUI

struct TrainingEntry: TimelineEntry {
    let date: Date
    let snapshot: TrainingSnapshot?
    var errorMessage: String? = nil
}

/// Ein Eintrag jetzt plus je einer pro Mitternacht der nächsten Woche, damit
/// "aktuelle Woche" und "Start in X Tagen" auch ohne neue Daten weiterlaufen.
/// Neue Daten stößt die App mit `reloadAllTimelines()` an.
struct TrainingProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrainingEntry {
        Self.entry(at: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainingEntry) -> Void) {
        completion(Self.entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainingEntry>) -> Void) {
        let first = Self.entry(at: .now)
        let cal = DateUtil.calendar
        let today = cal.startOfDay(for: .now)
        var entries = [first]
        for offset in 1...7 {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            entries.append(TrainingEntry(date: day, snapshot: first.snapshot, errorMessage: first.errorMessage))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func entry(at date: Date) -> TrainingEntry {
        do {
            return TrainingEntry(date: date, snapshot: try SnapshotStore.load())
        } catch {
            return TrainingEntry(date: date, snapshot: nil, errorMessage: error.localizedDescription)
        }
    }
}

// MARK: - Gemeinsame Widget-Bausteine

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
    /// Dezenter Farbverlauf in der Farbe der Einheit bzw. der Bewertung.
    func widgetBackground(tint: Color = .brand) -> some View {
        containerBackground(for: .widget) {
            LinearGradient(colors: [tint.opacity(0.22), Color.pageBackground],
                           startPoint: .topLeading, endPoint: .bottom)
        }
    }
}
