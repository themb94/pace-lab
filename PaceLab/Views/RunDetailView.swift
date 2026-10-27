import SwiftUI

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let run: Run
    let snapshot: TrainingSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !run.isAnalyzed { pending }
                metrics
                if let flags = run.flags, !flags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Notes"))
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(flags.enumerated()), id: \.offset) { index, flag in
                                if index > 0 { Divider() }
                                Text(flag)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 7)
                            }
                        }
                        .card(padding: 14)
                    }
                }
                if let splits = run.splits, !splits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(text: String(localized: "Splits"))
                            Spacer()
                            Text("Pace per km, color = heart-rate zone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            SplitsView(splits: splits, snapshot: snapshot)
                            ZoneLegend(snapshot: snapshot)
                        }
                        .card()
                    }
                }
                if let analysis = run.analysis {
                    TextBlock(title: String(localized: "Analysis"), text: analysis)
                }
                if let adjustments = run.adjustments {
                    TextBlock(title: String(localized: "Adjustment for next week"), text: adjustments)
                }
                if let dynamics = run.measuredDynamics {
                    RunningFormSection(run: run, dynamics: dynamics)
                }
                if let form = run.runningForm {
                    TextBlock(title: String(localized: "Running form, coach"), text: form)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        // Actions on the selected run live in the window's toolbar, not crammed next to the title.
        // Each action is its own item with a gap between them — in one group they merge into a single
        // glass capsule, and a `Link` would add its blue link color to it.
        .toolbar {
            ToolbarItem {
                AssignMenu(run: run, snapshot: snapshot)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    model.askCoach(about: run)
                } label: {
                    Label(run.isAnalyzed ? "Ask coach" : "Review", systemImage: "sparkles")
                }
                .help(run.isAnalyzed ? "Ask the coach about this run" : "Have the coach review this run")
            }
            if let url = run.stravaURL {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button { openURL(url) } label: {
                        Label("Open in Strava", systemImage: "arrow.up.right.square")
                    }
                    .help("Open in Strava")
                }
            } else if let url = run.garminURL {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button { openURL(url) } label: {
                        Label("Open in Garmin", systemImage: "arrow.up.right.square")
                    }
                    .help("Open in Garmin")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let day = run.day {
                Text(Fmt.longDate(day)).foregroundStyle(.secondary)
            }
            Text(run.name)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let label = snapshot.label(for: run) {
                    Label(label, systemImage: "calendar")
                        .foregroundStyle(.secondary)
                } else {
                    Text(run.tag ?? (run.isAnalyzed ? String(localized: "Unplanned") : String(localized: "Unassigned")))
                        .foregroundStyle(.secondary)
                }
                if let verdict = run.verdict { VerdictPill(verdict: verdict) }
            }
            .font(.callout)
        }
    }

    /// Freshly loaded, not yet rated.
    private var pending: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(.legible(.blue))
            VStack(alignment: .leading, spacing: 4) {
                Text("Not reviewed yet").font(.headline)
                let origin = run.source.flatMap { RunSource(rawValue: $0)?.shortLabel } ?? String(localized: "the watch")
                Text("Loaded from \(origin). The coach adds the rating, analysis and exact split names during the weekly review — or right away via “Review”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: .blue, padding: 14)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 16) {
                metricTiles
            }
            if let weather = run.weather {
                Divider()
                Label(WeatherInfo.summary(weather), systemImage: WeatherInfo(weather).symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(weather)
            }
        }
        .card()
    }

    @ViewBuilder
    private var metricTiles: some View {
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
            // The running dynamics section shows the cadence itself.
            if let cadence = run.stepsPerMinute, run.measuredDynamics?.cadenceSpm == nil {
                MetricTile(value: "\(Fmt.int(cadence)) spm", label: String(localized: "Cadence"), symbol: "metronome.fill")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .card()
        }
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

    /// The weather text itself, cut to its first part ("Garmin-Wetter beim Start: ca. 12 °C, …" →
    /// "ca. 12 °C, gefühlt ca. 12 °C, 67 % Luftfeuchte, …") — the full text is in the tooltip.
    static func summary(_ text: String) -> String {
        var t = text
        if let colon = t.firstIndex(of: ":"), t.distance(from: t.startIndex, to: colon) < 40 {
            t = String(t[t.index(after: colon)...])
        }
        if let semicolon = t.firstIndex(of: ";") { t = String(t[..<semicolon]) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
