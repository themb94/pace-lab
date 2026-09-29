import WidgetKit
import SwiftUI
import Charts

struct LastRunWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastRun", provider: TrainingProvider()) { entry in
            LastRunView(entry: entry)
        }
        .configurationDisplayName("Letzter Lauf")
        .description("Dein zuletzt analysierter Lauf mit Pace, Puls und Bewertung.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LastRunView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrainingEntry

    var body: some View {
        let run = entry.snapshot?.lastRun
        LastRunContent(entry: entry, family: family)
            .widgetURL(URL(string: run.map { "pacelab://run/\($0.id)" } ?? "pacelab://runs"))
            .widgetBackground(tint: run?.verdict?.color ?? .brand)
    }
}

struct LastRunContent: View {
    let entry: TrainingEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.snapshot, let run = snapshot.lastRun {
            if family == .systemMedium {
                HStack(spacing: 14) {
                    RunSummary(run: run)
                    if let splits = run.splits, splits.count > 1 {
                        MiniSplits(splits: splits, snapshot: snapshot)
                    }
                }
            } else {
                RunSummary(run: run)
            }
        } else if entry.snapshot != nil {
            WidgetMessage(symbol: "figure.run", text: "Noch keine Läufe")
        } else {
            WidgetMessage(symbol: "figure.run", text: entry.errorMessage ?? "Öffne Pace Lab einmal")
        }
    }
}

private struct RunSummary: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let verdict = run.verdict {
                    Image(systemName: verdict.symbol)
                        .foregroundStyle(verdict.color)
                        .widgetAccentable()
                }
                if let day = run.day {
                    Text(Fmt.weekdayDayMonth(day))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.weight(.semibold))

            Text(run.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            Spacer(minLength: 0)

            Text("\(Fmt.km(run.distanceKm, digits: 2)) km")
                .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label(Fmt.pace(run.paceSeconds), systemImage: "speedometer")
                if let hr = run.avgHr {
                    Label(Fmt.int(hr), systemImage: "heart.fill")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(TightLabelStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pace je Split als Balken (höher = schneller), eingefärbt nach HF-Zone.
private struct MiniSplits: View {
    let splits: [Split]
    let snapshot: TrainingSnapshot

    var body: some View {
        let speeds = splits.map { 1000 / max($0.paceS, 1) }
        let low = (speeds.min() ?? 0) * 0.85
        let high = speeds.max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            Chart(Array(splits.enumerated()), id: \.offset) { item in
                BarMark(
                    x: .value("Split", String(item.offset)),
                    yStart: .value("Basis", low),
                    yEnd: .value("Tempo", 1000 / max(item.element.paceS, 1)),
                    width: .ratio(0.75)
                )
                .foregroundStyle(HRZone.color(item.element.hr.map(snapshot.zone(forHR:)) ?? 1))
                .clipShape(.rect(cornerRadius: 2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: low...high)
            Text("Pace je km · Farbe = HF-Zone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
