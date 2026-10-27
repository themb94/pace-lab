import WidgetKit
import SwiftUI

struct NextSessionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NextSession", intent: SelectProfileIntent.self, provider: TrainingProvider()) { entry in
            NextSessionView(entry: entry)
        }
        .configurationDisplayName("Next session")
        .description("The next open session — large with the whole week and the last run.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NextSessionView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrainingEntry

    var body: some View {
        let next = entry.snapshot?.nextSession
        NextSessionContent(entry: entry, family: family)
            .widgetURL(entry.url(next.map { "session/\($0.id)" } ?? "plan"))
            .widgetBackground()
    }
}

/// Content without the widget environment — so it can also be rendered outside of WidgetKit.
struct NextSessionContent: View {
    let entry: TrainingEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.snapshot {
            if let next = snapshot.nextSession {
                content(snapshot, next)
            } else {
                WidgetMessage(symbol: "trophy.fill", text: String(localized: "All sessions done"))
            }
        } else {
            WidgetMessage(symbol: "figure.run", text: entry.errorMessage ?? String(localized: "Open Pace Lab once"))
        }
    }

    @ViewBuilder
    private func content(_ snapshot: TrainingSnapshot, _ session: PlannedSession) -> some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                SessionSummary(snapshot: snapshot, session: session, date: entry.date, entry: entry)
                Divider()
                WeekChecklist(snapshot: snapshot, week: snapshot.focusWeek(on: entry.date))
                    .frame(maxWidth: 160)
            }
        case .systemLarge:
            WeekOverview(snapshot: snapshot, session: session, date: entry.date, entry: entry)
        default:
            SessionSummary(snapshot: snapshot, session: session, date: entry.date, entry: entry)
        }
    }
}

private struct SessionSummary: View {
    let snapshot: TrainingSnapshot
    let session: PlannedSession
    let date: Date
    let entry: TrainingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                TypeTag(kind: session.kind)
                Spacer(minLength: 2)
                ProfileBadge(entry: entry)
            }

            Spacer(minLength: 0)

            Text(session.dist)
                .font(.figures(.title))
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
            return String(localized: "W\(session.week) · Starts \(Fmt.relativeDays(days))")
        }
        return String(localized: "Week \(session.week) · \(session.phase)")
    }
}

/// Session type as in the app: a swatch in the color of its intensity, then the name.
private struct TypeTag: View {
    let kind: SessionType

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.color)
                .frame(width: 12, height: 8)
                .widgetAccentable()
            Text(kind.label)
        }
        .font(.caption.weight(.semibold))
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
                Text("Week \(week)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                let done = snapshot.isDone(session)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : snapshot.state(of: session) == .dropped ? "minus.circle" : "circle")
                        .foregroundStyle(done ? AnyShapeStyle(.legible(.green)) : AnyShapeStyle(Color.secondary))
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
            }
            Spacer(minLength: 0)
            Text("\(Fmt.km(actual)) / \(Fmt.km(planned, digits: 0)) km")
                .font(.figures(.caption2, weight: .regular))
                .foregroundStyle(.secondary)
            WeekBars(snapshot: snapshot, week: week, scaleKm: max(planned, actual), height: 8, showLabels: false)
        }
    }
}

/// Large widget: next session, the whole week and the last run.
private struct WeekOverview: View {
    let snapshot: TrainingSnapshot
    let session: PlannedSession
    let date: Date
    let entry: TrainingEntry

    var body: some View {
        let week = snapshot.focusWeek(on: date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.progressLine(on: date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.plan.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProfileBadge(entry: entry)
            }

            VStack(alignment: .leading, spacing: 2) {
                TypeTag(kind: session.kind)
                Text(session.dist)
                    .font(.figures(.largeTitle))
                Text(session.desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Text("Week \(week) · \(snapshot.phase(ofWeek: week))")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            WeekChecklist(snapshot: snapshot, week: week, showDescriptions: true)

            if let run = snapshot.lastRun {
                Divider()
                HStack(spacing: 6) {
                    if let verdict = run.verdict {
                        Image(systemName: verdict.symbol).foregroundStyle(.legible(verdict.color))
                            .accessibilityLabel(verdict.label)
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
