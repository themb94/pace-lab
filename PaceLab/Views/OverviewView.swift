import SwiftUI

/// The block at a glance: goal, the next session, one row of effort bars per week and the last run.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot, today: .now)
            } else {
                LoadErrorView()
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.snapshot?.plan.title ?? "")
        .toolbar {
            ToolbarItem {
                Button {
                    model.startCoach(.reviewWeek)
                } label: {
                    Label("Review week", systemImage: "sparkles")
                }
                .help("Claude reviews the last week (Strava → analysis)")
                .disabled(model.coach.isRunning)
            }
        }
    }

    private func content(_ snapshot: TrainingSnapshot, today: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let error = model.loadError { ErrorBanner(message: error) }

                BlockHeader(snapshot: snapshot, today: today)

                if let next = snapshot.nextSession {
                    NextUpRow(session: next)
                }

                BlockMap(snapshot: snapshot, focusWeek: snapshot.focusWeek(on: today),
                         isRunning: snapshot.status(on: today) != .finished)

                if let run = snapshot.lastRun {
                    LastRunRow(run: run, label: snapshot.label(for: run))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.pageBackground)
    }
}

// MARK: - Head

private struct BlockHeader: View {
    let snapshot: TrainingSnapshot
    let today: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.progressLine(on: today))
                .font(.title3)
                .foregroundStyle(.secondary)
            if let subtitle = snapshot.plan.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard let goal = snapshot.plan.goal, !goal.isEmpty else { return snapshot.plan.title }
        return goal.prefix(1).uppercased() + goal.dropFirst()
    }
}

// MARK: - Next session

private struct NextUpRow: View {
    @Environment(AppModel.self) private var model
    let session: PlannedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next in week \(session.week)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.dist)
                    .font(.figures(size: 30))
                Text(session.kind.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.legible(session.kind.color))
                Spacer(minLength: 16)
                Button {
                    withAnimation { model.toggleDone(session) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                Button("Show in plan") { model.show(session) }
            }
            .controlSize(.large)
            Text(session.desc)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Block map

/// One row per block week; every session a bar (length = km, color = intensity, form = state).
private struct BlockMap: View {
    @Environment(AppModel.self) private var model
    let snapshot: TrainingSnapshot
    let focusWeek: Int
    let isRunning: Bool

    var body: some View {
        let scale = snapshot.longestWeekKm
        VStack(alignment: .leading, spacing: 2) {
            ForEach(1...max(snapshot.weekCount, 1), id: \.self) { week in
                row(week, scale: scale)
            }
            EffortLegend()
                .padding(.top, 10)
                .padding(.leading, 8)
        }
    }

    private func row(_ week: Int, scale: Double) -> some View {
        let isCurrent = isRunning && week == focusWeek
        let isPast = week < focusWeek || (week == focusWeek && !isRunning)
        let planned = snapshot.plannedKm(week: week)
        let actual = snapshot.actualKm(week: week)
        return HStack(spacing: 12) {
            Text("W\(week)")
                .font(.figures(.callout, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 40, alignment: .leading)
            WeekBars(snapshot: snapshot, week: week, scaleKm: scale, height: 20) { model.show($0) }
            Text(snapshot.phase(ofWeek: week))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            Group {
                if isCurrent || (isPast && actual < planned - 2) {
                    Text("\(Text(Fmt.km(actual, digits: 0)).font(.figures(.callout))) \(Text("of \(Fmt.km(planned, digits: 0)) km").foregroundStyle(.secondary))")
                } else if isPast {
                    Text("\(Fmt.km(actual, digits: 0)) km").font(.figures(.callout))
                } else {
                    Text("\(Fmt.km(planned, digits: 0)) km").font(.figures(.callout, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .help(String(localized: "Week \(week) · \(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week)))")
              + (snapshot.note(ofWeek: week).map { "\n\($0)" } ?? ""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Week \(week)"))
    }
}

/// What the bars mean: color = intensity, form = state.
struct EffortLegend: View {
    var body: some View {
        FlowLayout(spacing: 16) {
            swatch(SessionType.easy.color, String(localized: "Easy and long"))
            swatch(SessionType.tempo.color, "Tempo")
            swatch(SessionType.race.color, String(localized: "Race"))
            shape(String(localized: "run")) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary)
            }
            shape(String(localized: "planned")) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
            shape(String(localized: "dropped")) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2]))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        shape(text) { RoundedRectangle(cornerRadius: 2).fill(color) }
    }

    private func shape(_ text: String, @ViewBuilder _ mark: () -> some View) -> some View {
        HStack(spacing: 5) {
            mark().frame(width: 16, height: 9).accessibilityHidden(true)
            Text(text)
        }
    }
}

// MARK: - Last run

private struct LastRunRow: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let label: String?

    var body: some View {
        Button { model.show(run) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("Last run")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let day = run.day {
                        Text(Fmt.weekdayDayMonth(day) + (label.map { ", \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text("\(Fmt.km(run.distanceKm, digits: 2)) km").font(.figures(.callout))
                Text("\(Fmt.pace(run.paceSeconds)) /km").font(.figures(.callout))
                if let hr = run.avgHr {
                    Text("\(Fmt.int(hr)) bpm").font(.figures(.callout))
                }
                if let verdict = run.verdict { VerdictPill(verdict: verdict) }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
        }
        .buttonStyle(CardButtonStyle())
    }
}
