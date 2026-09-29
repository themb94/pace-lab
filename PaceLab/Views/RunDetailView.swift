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
                        SectionTitle(text: "Splits · Pace & Herzfrequenz")
                        VStack(alignment: .leading, spacing: 12) {
                            SplitsView(splits: splits, snapshot: snapshot)
                            ZoneLegend(snapshot: snapshot)
                        }
                        .card()
                    }
                }
                if let analysis = run.analysis {
                    TextBlock(title: "Analyse", text: analysis, color: .brand)
                }
                if let adjustments = run.adjustments {
                    TextBlock(title: "Anpassung Folgewoche", text: adjustments, color: Color(hex: 0xE0A800))
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
                    Pill(text: run.tag ?? (run.isAnalyzed ? "Außerplanmäßig" : "Nicht zugeordnet"),
                         color: run.isAnalyzed ? .purple : .gray)
                }
                if let verdict = run.verdict { VerdictPill(verdict: verdict) }
                Spacer(minLength: 12)
                AssignMenu(run: run, snapshot: snapshot)
                Button {
                    model.askCoach(about: run)
                } label: {
                    Label(run.isAnalyzed ? "Coach fragen" : "Auswerten", systemImage: "sparkles")
                }
                if let url = run.stravaURL {
                    Link(destination: url) {
                        Label("In Strava öffnen", systemImage: "arrow.up.right.square")
                    }
                } else if let url = run.garminURL {
                    Link(destination: url) {
                        Label("In Garmin öffnen", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    /// Frisch geladen, noch ohne Bewertung.
    private var pending: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Noch nicht ausgewertet").font(.headline)
                Text("Geladen von \(run.source == "strava" ? "Strava" : run.source == "garmin" ? "Garmin" : "der Uhr"). Bewertung, Analyse und genaue Split-Namen ergänzt der Coach bei der Wochenauswertung — oder jetzt über „Auswerten“.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: .blue, padding: 14)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            MetricTile(value: "\(Fmt.km(run.distanceKm, digits: 2)) km", label: "Distanz", symbol: "ruler")
            MetricTile(value: Fmt.duration(run.movingTimeS), label: "Zeit", symbol: "stopwatch")
            MetricTile(value: "\(Fmt.pace(run.paceSeconds))/km", label: "Ø Pace", symbol: "speedometer")
            if let hr = run.avgHr {
                MetricTile(value: "\(Fmt.int(hr)) bpm", label: "Ø HF", symbol: "heart.fill")
            }
            if let hr = run.maxHr {
                MetricTile(value: "\(Fmt.int(hr)) bpm", label: "Max HF", symbol: "heart.circle")
            }
            if let effort = run.relativeEffort {
                MetricTile(value: Fmt.int(effort), label: "Anstrengung", symbol: "flame.fill")
            }
            if let elevation = run.elevationGain {
                MetricTile(value: "\(Fmt.int(elevation)) m", label: "Anstieg", symbol: "mountain.2.fill")
            }
            if let cadence = run.cadence {
                MetricTile(value: "\(Fmt.int(cadence)) spm", label: "Kadenz", symbol: "metronome.fill")
            }
            if let weather = run.weather {
                let info = WeatherInfo(weather)
                MetricTile(value: info.label, label: "Bedingungen", symbol: info.symbol)
                    .help(weather)
            }
        }
    }
}

/// Lauf einer Plan-Einheit zuordnen (setzt sessionId und hakt die Einheit mit dem Laufdatum ab).
private struct AssignMenu: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let snapshot: TrainingSnapshot

    var body: some View {
        let suggestions = SessionMatcher.suggestions(date: run.date, distanceKm: run.distanceKm, in: snapshot)
        let runDay = run.day.map(DateUtil.germanDay)
        Menu {
            if suggestions.isEmpty {
                Text("Kein Plan-Tag: Der Lauf liegt außerhalb des Blocks.")
            }
            ForEach(suggestions) { session in
                Button {
                    model.assign(run, to: session)
                } label: {
                    let other = snapshot.isDone(session) && snapshot.doneDate(session) != runDay && session.id != run.sessionId
                    Text("W\(session.week) · \(session.kind.label) \(session.dist)"
                         + (session.id == run.sessionId ? "  ✓" : other ? "  (schon erledigt)" : ""))
                }
                .disabled(session.id == run.sessionId)
            }
            if run.sessionId != nil {
                Divider()
                Button("Zuordnung lösen") { model.assign(run, to: nil) }
            }
        } label: {
            Label("Zuordnen", systemImage: "link")
        }
        .fixedSize()
        .help("Lauf einer Einheit im Plan zuordnen und sie abhaken")
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

/// Grobe Einordnung des freien Wetter-Texts.
private struct WeatherInfo {
    let label: String
    let symbol: String

    init(_ text: String) {
        let t = text.lowercased()
        if t.contains("heiß") { (label, symbol) = ("heiß", "thermometer.sun.fill") }
        else if t.contains("warm") { (label, symbol) = ("warm", "thermometer.medium") }
        else if t.contains("kühl") { (label, symbol) = ("kühl", "thermometer.low") }
        else if t.contains("kalt") { (label, symbol) = ("kalt", "snowflake") }
        else if t.contains("regen") { (label, symbol) = ("Regen", "cloud.rain.fill") }
        else { (label, symbol) = ("Wetter", "cloud.sun.fill") }
    }
}
