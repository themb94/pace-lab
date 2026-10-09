import SwiftUI

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let snapshot: TrainingSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !run.isAnalyzed { pending }
                metrics
                if let flags = run.flags, !flags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(flags, id: \.self) { flag in
                            Text(flag)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.subtleFill, in: Capsule())
                        }
                    }
                }
                if let splits = run.splits, !splits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Splits · pace & heart rate"))
                        VStack(alignment: .leading, spacing: 12) {
                            SplitsView(splits: splits, snapshot: snapshot)
                            ZoneLegend(snapshot: snapshot)
                        }
                        .card()
                    }
                }
                if let analysis = run.analysis {
                    TextBlock(title: String(localized: "Analysis"), text: analysis, color: .brand)
                }
                if let adjustments = run.adjustments {
                    TextBlock(title: String(localized: "Adjustment for next week"), text: adjustments, color: Color(hex: 0xE0A800))
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let day = run.day {
                Text(Fmt.longDate(day)).foregroundStyle(.secondary)
            }
            Text(run.name)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let label = snapshot.label(for: run) {
                    Pill(text: label, symbol: "calendar", color: .blue)
                } else {
                    Pill(text: run.tag ?? (run.isAnalyzed ? String(localized: "Unplanned") : String(localized: "Unassigned")),
                         color: run.isAnalyzed ? .purple : .gray)
                }
                if let verdict = run.verdict { VerdictPill(verdict: verdict) }
                Spacer(minLength: 12)
                AssignMenu(run: run, snapshot: snapshot)
                Button {
                    model.askCoach(about: run)
                } label: {
                    Label(run.isAnalyzed ? "Ask coach" : "Review", systemImage: "sparkles")
                }
                if let url = run.stravaURL {
                    Link(destination: url) {
                        Label("Open in Strava", systemImage: "arrow.up.right.square")
                    }
                } else if let url = run.garminURL {
                    Link(destination: url) {
                        Label("Open in Garmin", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    /// Freshly loaded, not yet rated.
    private var pending: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not reviewed yet").font(.headline)
                let origin = run.source == "strava" ? "Strava" : run.source == "garmin" ? "Garmin" : String(localized: "the watch")
                Text("Loaded from \(origin). The coach adds the rating, analysis and exact split names during the weekly review — or right away via “Review”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: .blue, padding: 14)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            MetricTile(value: "\(Fmt.km(run.distanceKm, digits: 2)) km", label: String(localized: "Distance"), symbol: "ruler")
            MetricTile(value: Fmt.duration(run.movingTimeS), label: String(localized: "Time"), symbol: "stopwatch")
            MetricTile(value: "\(Fmt.pace(run.paceSeconds))/km", label: String(localized: "Avg pace"), symbol: "speedometer")
            if let hr = run.avgHr {
                MetricTile(value: "\(Fmt.int(hr)) bpm", label: String(localized: "Avg HR"), symbol: "heart.fill")
            }
            if let hr = run.maxHr {
                MetricTile(value: "\(Fmt.int(hr)) bpm", label: String(localized: "Max HR"), symbol: "heart.circle")
            }
            if let effort = run.relativeEffort {
                MetricTile(value: Fmt.int(effort), label: String(localized: "Effort"), symbol: "flame.fill")
            }
            if let elevation = run.elevationGain {
                MetricTile(value: "\(Fmt.int(elevation)) m", label: String(localized: "Climb"), symbol: "mountain.2.fill")
            }
            if let cadence = run.cadence {
                MetricTile(value: "\(Fmt.int(cadence)) spm", label: String(localized: "Cadence"), symbol: "metronome.fill")
            }
            if let weather = run.weather {
                let info = WeatherInfo(weather)
                MetricTile(value: info.label, label: String(localized: "Conditions"), symbol: info.symbol)
                    .help(weather)
            }
        }
    }
}

/// Assign a run to a plan session (sets sessionId and checks off the session with the run's date).
private struct AssignMenu: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let snapshot: TrainingSnapshot

    var body: some View {
        let suggestions = SessionMatcher.suggestions(date: run.date, distanceKm: run.distanceKm, in: snapshot)
        let runDay = run.day.map(DateUtil.germanDay)
        Menu {
            if suggestions.isEmpty {
                Text(String(localized: "Not a plan day: this run is outside the block."))
            }
            ForEach(suggestions) { session in
                Button {
                    model.assign(run, to: session)
                } label: {
                    let other = snapshot.isDone(session) && snapshot.doneDate(session) != runDay && session.id != run.sessionId
                    Text("W\(session.week) · \(session.kind.label) \(session.dist)"
                         + (session.id == run.sessionId ? "  ✓" : other ? String(localized: "  (already done)") : ""))
                }
                .disabled(session.id == run.sessionId)
            }
            if run.sessionId != nil {
                Divider()
                Button(String(localized: "Unassign")) { model.assign(run, to: nil) }
            }
        } label: {
            Label(String(localized: "Assign"), systemImage: "link")
        }
        .fixedSize()
        .help(String(localized: "Assign this run to a session in the plan and tick it off"))
        .disabled(model.coach.isRunning || model.sync.isRunning)
    }
}

private struct TextBlock: View {
    let title: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .textCase(.uppercase)
                Text(text)
                    .font(.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
        }
        .card()
    }
}

/// Rough classification of the free-form weather text.
private struct WeatherInfo {
    let label: String
    let symbol: String

    init(_ text: String) {
        let t = text.lowercased()
        if t.contains("heiß") || t.contains("hot") { (label, symbol) = (String(localized: "hot"), "thermometer.sun.fill") }
        else if t.contains("warm") { (label, symbol) = (String(localized: "warm"), "thermometer.medium") }
        else if t.contains("kühl") || t.contains("cool") { (label, symbol) = (String(localized: "cool"), "thermometer.low") }
        else if t.contains("kalt") || t.contains("cold") { (label, symbol) = (String(localized: "cold"), "snowflake") }
        else if t.contains("regen") || t.contains("rain") { (label, symbol) = (String(localized: "Rain"), "cloud.rain.fill") }
        else { (label, symbol) = (String(localized: "Weather"), "cloud.sun.fill") }
    }
}
