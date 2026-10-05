import WidgetKit
import SwiftUI

struct WeekProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WeekProgress", provider: TrainingProvider()) { entry in
            WeekProgressView(entry: entry)
        }
        .configurationDisplayName("Week progress")
        .description("Kilometers run vs. planned and sessions completed this week.")
        .supportedFamilies([.systemSmall])
    }
}

struct WeekProgressView: View {
    let entry: TrainingEntry

    var body: some View {
        WeekProgressContent(entry: entry)
            .widgetURL(URL(string: "pacelab://plan"))
            .widgetBackground()
    }
}

struct WeekProgressContent: View {
    let entry: TrainingEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot, week: snapshot.focusWeek(on: entry.date))
        } else {
            WidgetMessage(symbol: "figure.run", text: entry.errorMessage ?? String(localized: "Open Pace Lab once"))
        }
    }

    private func content(_ snapshot: TrainingSnapshot, week: Int) -> some View {
        let sessions = snapshot.sessions(inWeek: week)
        let done = sessions.filter(snapshot.isDone).count
        let planned = snapshot.plannedKm(week: week)
        let actual = snapshot.actualKm(week: week)
        let progress = planned > 0 ? min(actual / planned, 1) : 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(header(snapshot, week: week))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(done)/\(sessions.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(done == sessions.count ? .green : .secondary)
            }

            ZStack {
                Circle().stroke(.quaternary, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                VStack(spacing: -2) {
                    Text(Fmt.km(actual))
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                    Text("of \(Fmt.km(planned, digits: 0)) km")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    Capsule()
                        .fill(snapshot.isDone(session) ? AnyShapeStyle(session.kind.color) : AnyShapeStyle(.quaternary))
                        .frame(height: 5)
                }
            }
        }
    }

    private func header(_ snapshot: TrainingSnapshot, week: Int) -> String {
        if case .upcoming(let days) = snapshot.status(on: entry.date) {
            return String(localized: "Starts \(Fmt.relativeDays(days))")
        }
        return String(localized: "Week \(week)/\(snapshot.weekCount)")
    }
}
