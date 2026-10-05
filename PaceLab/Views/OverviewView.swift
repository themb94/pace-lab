import SwiftUI
import Charts

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
        .navigationTitle(model.snapshot?.plan.title ?? "Pace Lab")
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
        let week = snapshot.focusWeek(on: today)
        let monday = DateUtil.startOfWeek(today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.loadError { ErrorBanner(message: error) }

                BlockHeaderCard(snapshot: snapshot, today: today)

                AdaptiveColumns {
                    if let next = snapshot.nextSession {
                        NextSessionCard(session: next)
                    }
                    WeekCard(snapshot: snapshot, week: week, today: today)
                } trailing: {
                    if let run = snapshot.lastRun {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: String(localized: "Last run"))
                            Button { model.show(run) } label: {
                                LastRunCard(run: run, label: snapshot.label(for: run))
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Weekly distance"))
                        WeeklyKmChart(
                            buckets: snapshot.weeklyBuckets(
                                from: DateUtil.calendar.date(byAdding: .day, value: -42, to: monday)!, count: 10),
                            currentMonday: monday
                        )
                        .card()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color.pageBackground)
    }
}

// MARK: - Kopf

private struct BlockHeaderCard: View {
    let snapshot: TrainingSnapshot
    let today: Date

    var body: some View {
        let total = snapshot.sessions.count
        let done = snapshot.doneCount
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                if let goal = snapshot.plan.goal {
                    Text(goal.prefix(1).uppercased() + goal.dropFirst())
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.brand)
                }
                if let subtitle = snapshot.plan.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Label(statusText, systemImage: statusSymbol)
                    .font(.callout.weight(.semibold))
                    .padding(.top, 2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 28) {
                StatBlock(value: weekValue, total: "/\(snapshot.weekCount)", label: String(localized: "Block week"), color: .brand)
                StatBlock(value: "\(done)", total: "/\(total)", label: String(localized: "Sessions"), color: .green)
                StatBlock(value: Fmt.km(snapshot.totalKm, digits: 0), total: " km", label: String(localized: "analyzed"), color: .blue)
            }
        }
        .overlay(alignment: .bottom) {
            ProgressBar(value: total > 0 ? Double(done) / Double(total) : 0)
                .offset(y: 14)
        }
        .padding(.bottom, 14)
        .card()
    }

    private var weekValue: String {
        switch snapshot.status(on: today) {
        case .upcoming: "–"
        case .running(let week): "\(week)"
        case .finished: "\(snapshot.weekCount)"
        }
    }

    private var statusText: String {
        switch snapshot.status(on: today) {
        case .upcoming(let days):
            String(localized: "Starts \(Fmt.relativeDays(days)) · \(Fmt.weekdayDayMonth(snapshot.startMonday))")
        case .running(let week):
            String(localized: "Week \(week) of \(snapshot.weekCount) · \(snapshot.phase(ofWeek: week))")
        case .finished:
            String(localized: "Block completed")
        }
    }

    private var statusSymbol: String {
        switch snapshot.status(on: today) {
        case .upcoming: "flag"
        case .running: "figure.run"
        case .finished: "trophy.fill"
        }
    }
}

private struct StatBlock: View {
    let value: String
    let total: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Text(value).foregroundStyle(color))\(Text(total).foregroundStyle(.secondary).font(.title3))")
                .font(.largeTitle.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Nächstes Training

private struct NextSessionCard: View {
    @Environment(AppModel.self) private var model
    let session: PlannedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up next · Week \(session.week) · \(session.phase)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.brand)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.dist)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                TypePill(kind: session.kind)
            }
            Text(session.desc)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    withAnimation { model.toggleDone(session) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    model.show(session)
                } label: {
                    Label("Show in plan", systemImage: "calendar")
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .card(tint: session.kind.color)
    }
}

// MARK: - Woche

private struct WeekCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: TrainingSnapshot
    let week: Int
    let today: Date

    var body: some View {
        let sessions = snapshot.sessions(inWeek: week)
        let done = sessions.filter(snapshot.isDone).count
        let planned = snapshot.plannedKm(week: week)
        let actual = snapshot.actualKm(week: week)

        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Week \(week)").font(.headline)
                    PhasePill(phase: snapshot.phase(ofWeek: week))
                    Text(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))
                         + (snapshot.note(ofWeek: week).map { " · \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(done)/\(sessions.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(done == sessions.count ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Fmt.km(actual)) of \(Fmt.km(planned, digits: 0)) km")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    ProgressBar(value: planned > 0 ? actual / planned : 0)
                }

                ForEach(sessions) { session in
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        DoneToggle(isDone: snapshot.isDone(session)) {
                            withAnimation { model.toggleDone(session) }
                        }
                        Button { model.show(session) } label: {
                            HStack {
                                SessionRowContent(
                                    session: session,
                                    isDone: snapshot.isDone(session),
                                    doneDate: snapshot.doneDate(session),
                                    hasRun: snapshot.linkedRun(for: session) != nil)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .card()
        }
    }

    private var title: String {
        switch snapshot.status(on: today) {
        case .upcoming: String(localized: "First week")
        case .running: String(localized: "This week")
        case .finished: String(localized: "Last week")
        }
    }
}

// MARK: - Letzter Lauf

private struct LastRunCard: View {
    let run: Run
    let label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let day = run.day {
                        Text(Fmt.weekdayDayMonth(day)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(run.name).font(.headline)
                }
                Spacer()
                if let verdict = run.verdict { VerdictPill(verdict: verdict) }
            }
            HStack(spacing: 8) {
                MetricTile(value: "\(Fmt.km(run.distanceKm, digits: 2)) km", label: String(localized: "Distance"), symbol: "ruler")
                MetricTile(value: Fmt.pace(run.paceSeconds), label: String(localized: "Avg pace"), symbol: "speedometer")
                MetricTile(value: Fmt.int(run.avgHr), label: String(localized: "Avg HR"), symbol: "heart.fill")
            }
            if let label {
                Pill(text: label, color: .blue)
            } else if let tag = run.tag {
                Pill(text: tag, color: .purple)
            }
        }
        .card()
    }
}

// MARK: - Wochenkilometer

struct WeeklyKmChart: View {
    let buckets: [WeekBucket]
    let currentMonday: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(buckets) { bucket in
                if let planned = bucket.plannedKm {
                    BarMark(x: .value("Week", label(bucket)), y: .value("km", planned),
                            width: .ratio(0.62), stacking: .unstacked)
                        .foregroundStyle(Color.primary.opacity(0.13))
                        .clipShape(.rect(cornerRadius: 4))
                }
                BarMark(x: .value("Week", label(bucket)), y: .value("km", bucket.actualKm),
                        width: .ratio(0.62), stacking: .unstacked)
                    .foregroundStyle(bucket.monday == currentMonday ? Color.brand : Color.brand.opacity(0.55))
                    .clipShape(.rect(cornerRadius: 4))
                    .annotation(position: .top, spacing: 2) {
                        if bucket.actualKm > 0 {
                            Text(Fmt.km(bucket.actualKm, digits: 0))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 200)

            HStack(spacing: 14) {
                legendItem(Color.brand, String(localized: "actual"))
                legendItem(Color.primary.opacity(0.13), String(localized: "planned"))
                Spacer()
                Text("W = block week, otherwise Monday of the week")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func label(_ bucket: WeekBucket) -> String {
        if let week = bucket.blockWeek { return "W\(week)" }
        return Fmt.dayMonth(bucket.monday)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
