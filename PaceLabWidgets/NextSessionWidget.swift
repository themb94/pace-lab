import WidgetKit
import SwiftUI

struct NextSessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextSession", provider: TrainingProvider()) { entry in
            NextSessionView(entry: entry)
        }
        .configurationDisplayName("Nächstes Training")
        .description("Die nächste offene Einheit — groß mit der ganzen Woche und dem letzten Lauf.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NextSessionView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrainingEntry

    var body: some View {
        let next = entry.snapshot?.nextSession
        // Groß zeigt es die ganze Woche → neutraler Markenton statt der Farbe der nächsten Einheit.
        let tint = family == .systemLarge ? Color.brand : (next?.kind.color ?? .brand)
        NextSessionContent(entry: entry, family: family)
            .widgetURL(URL(string: next.map { "pacelab://session/\($0.id)" } ?? "pacelab://plan"))
            .widgetBackground(tint: tint)
    }
}

/// Inhalt ohne Widget-Umgebung — so lässt er sich auch außerhalb von WidgetKit rendern.
struct NextSessionContent: View {
    let entry: TrainingEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.snapshot {
            if let next = snapshot.nextSession {
                content(snapshot, next)
            } else {
                WidgetMessage(symbol: "trophy.fill", text: "Alle Einheiten erledigt")
            }
        } else {
            WidgetMessage(symbol: "figure.run", text: entry.errorMessage ?? "Öffne Pace Lab einmal")
        }
    }

    @ViewBuilder
    private func content(_ snapshot: TrainingSnapshot, _ session: PlannedSession) -> some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                SessionSummary(snapshot: snapshot, session: session, date: entry.date)
                Divider()
                WeekChecklist(snapshot: snapshot, week: snapshot.focusWeek(on: entry.date))
                    .frame(maxWidth: 160)
            }
        case .systemLarge:
            WeekOverview(snapshot: snapshot, session: session, date: entry.date)
        default:
            SessionSummary(snapshot: snapshot, session: session, date: entry.date)
        }
    }
}

private struct SessionSummary: View {
    let snapshot: TrainingSnapshot
    let session: PlannedSession
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: session.kind.symbol)
                Text(session.kind.shortLabel)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(session.kind.color)
            .widgetAccentable()

            Spacer(minLength: 0)

            Text(session.dist)
                .font(.system(.title, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(session.desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Spacer(minLength: 0)

            Text(footer)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: String {
        if case .upcoming(let days) = snapshot.status(on: date) {
            return "W\(session.week) · Start \(Fmt.relativeDays(days))"
        }
        return "Woche \(session.week) · \(session.phase)"
    }
}

struct WeekChecklist: View {
    let snapshot: TrainingSnapshot
    let week: Int
    var showDescriptions = false

    var body: some View {
        let sessions = snapshot.sessions(inWeek: week)
        let planned = snapshot.plannedKm(week: week)
        let actual = snapshot.actualKm(week: week)
        VStack(alignment: .leading, spacing: showDescriptions ? 8 : 6) {
            if !showDescriptions {
                Text("Woche \(week)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                let done = snapshot.isDone(session)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.green : Color.secondary)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(session.kind.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(session.dist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if showDescriptions {
                            Text(session.desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .opacity(done ? 0.6 : 1)
            }
            Spacer(minLength: 0)
            Text("\(Fmt.km(actual)) / \(Fmt.km(planned, digits: 0)) km")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            WidgetBar(value: planned > 0 ? actual / planned : 0)
        }
    }
}

/// Großes Widget: nächste Einheit, die ganze Woche und der letzte Lauf.
private struct WeekOverview: View {
    let snapshot: TrainingSnapshot
    let session: PlannedSession
    let date: Date

    var body: some View {
        let week = snapshot.focusWeek(on: date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.statusLine(on: date))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .widgetAccentable()
                Spacer()
                Text(snapshot.plan.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Label(session.kind.label, systemImage: session.kind.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(session.kind.color)
                Text(session.dist)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(session.desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Text("Woche \(week) · \(snapshot.phase(ofWeek: week))")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            WeekChecklist(snapshot: snapshot, week: week, showDescriptions: true)

            if let run = snapshot.lastRun {
                Divider()
                HStack(spacing: 6) {
                    if let verdict = run.verdict {
                        Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
                    }
                    Text(run.day.map(Fmt.weekdayDayMonth) ?? "")
                        .foregroundStyle(.secondary)
                    Text(run.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Fmt.km(run.distanceKm)) km · \(Fmt.pace(run.paceSeconds))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}
