import SwiftUI

// MARK: - Karten & Pillen

struct CardModifier: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.03)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
            }
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = 18) -> some View {
        modifier(CardModifier(tint: tint, padding: padding))
    }
}

struct Pill: View {
    let text: String
    var symbol: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct TypePill: View {
    let kind: SessionType
    var body: some View { Pill(text: kind.shortLabel, symbol: kind.symbol, color: kind.color) }
}

struct PhasePill: View {
    let phase: String
    var body: some View { Pill(text: phase.uppercased(), color: PhaseStyle.color(phase)) }
}

struct VerdictPill: View {
    let verdict: Verdict
    var body: some View { Pill(text: verdict.label, symbol: verdict.symbol, color: verdict.color) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = .brand

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

/// Ganze Karte klickbar, mit dezentem Hover-Effekt.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Erledigt-Knopf

struct DoneToggle: View {
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isDone ? "Als offen markieren (completed.json)" : "Als erledigt markieren (completed.json)")
        .accessibilityLabel(isDone ? "Als offen markieren" : "Als erledigt markieren")
    }
}

// MARK: - Zeilen

/// Inhalt einer Plan-Einheit (ohne Erledigt-Knopf).
struct SessionRowContent: View {
    let session: PlannedSession
    let isDone: Bool
    var doneDate: String? = nil
    var hasRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TypePill(kind: session.kind)
                Text(session.dist)
                    .font(.headline)
                    .strikethrough(isDone, color: .secondary)
                if hasRun {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help("Analyse vorhanden")
                }
            }
            Text(session.desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let doneDate {
                Text("✓ erledigt am \(doneDate)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .opacity(isDone ? 0.65 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunRow: View {
    let run: Run
    let label: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(run.isAnalyzed ? (run.verdict ?? .ok).color : Color.secondary.opacity(0.35))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let day = run.day {
                        Text(Fmt.weekdayDayMonth(day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !run.isAnalyzed {
                        Text("NEU")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                            .help("Geladen, aber noch nicht vom Coach ausgewertet")
                    }
                    Spacer()
                    Text("\(Fmt.km(run.distanceKm)) km")
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                Text(run.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(label ?? run.tag ?? (run.isAnalyzed ? "Außerplanmäßig" : "Noch keiner Einheit zugeordnet"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(label != nil ? Color.blue : run.isAnalyzed ? Color.purple : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Label("\(Fmt.pace(run.paceSeconds))/km", systemImage: "speedometer")
                    if let hr = run.avgHr {
                        Label(Fmt.int(hr), systemImage: "heart.fill")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
            }
        }
        .padding(.vertical, 3)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Kennzahlen

struct MetricTile: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.subtleFill, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Splits

struct SplitsView: View {
    let splits: [Split]
    let snapshot: TrainingSnapshot

    var body: some View {
        let fastest = splits.map(\.paceS).filter { $0 > 0 }.min() ?? 1
        VStack(spacing: 5) {
            ForEach(Array(splits.enumerated()), id: \.offset) { _, split in
                let zone = split.hr.map(snapshot.zone(forHR:))
                let color = zone.map(HRZone.color) ?? Color.gray
                HStack(spacing: 10) {
                    Text(split.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        let ratio = max(0.38, fastest / max(split.paceS, 1))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(color.gradient)
                            .frame(width: geo.size.width * ratio)
                            .overlay(alignment: .leading) {
                                Text(Fmt.pace(split.paceS))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.black.opacity(0.8))
                                    .padding(.leading, 7)
                            }
                    }
                    .frame(height: 22)
                    Group {
                        if let hr = split.hr, let zone {
                            Text("\(Fmt.int(hr)) bpm · Z\(zone)")
                        } else {
                            Text("")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .trailing)
                }
            }
        }
    }
}

struct ZoneLegend: View {
    let snapshot: TrainingSnapshot

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(snapshot.zoneLegend, id: \.zone) { item in
                HStack(spacing: 4) {
                    Circle().fill(HRZone.color(item.zone)).frame(width: 8, height: 8)
                    Text("Z\(item.zone) \(item.range)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Fließlayout (Flags, Legenden)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: .init(width: width, height: size.height))
                x += width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: maxWidth, height: nil))
            let itemWidth = min(size.width, maxWidth)
            if !current.indices.isEmpty, current.width + spacing + itemWidth > maxWidth {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Zwei Spalten, wenn Platz ist

struct AdaptiveColumns<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 20
    var minColumnWidth: CGFloat = 380
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                VStack(spacing: spacing) { leading }.frame(minWidth: minColumnWidth)
                VStack(spacing: spacing) { trailing }.frame(minWidth: minColumnWidth)
            }
            VStack(spacing: spacing) {
                leading
                trailing
            }
        }
    }
}

// MARK: - Fehlerzustände

struct LoadErrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("Keine Trainingsdaten", systemImage: "folder.badge.questionmark")
        } description: {
            Text(model.loadError ?? "Die Daten konnten nicht geladen werden.")
            Text(model.folder.url.path).font(.caption).foregroundStyle(.secondary)
        } actions: {
            HStack {
                Button("Einrichtung öffnen …") { openWindow(id: "setup") }
                    .buttonStyle(.borderedProminent)
                Button("Erneut laden") { model.reload(force: true) }
                SettingsLink { Text("Ordner ändern …") }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .card(tint: .orange, padding: 12)
    }
}
