import SwiftUI

// MARK: - Cards & pills

/// A quiet surface for grouped content. `tint` only for messages (warnings, errors) — a flat wash,
/// never a gradient.
struct CardModifier: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.10))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    }
            }
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(CardModifier(tint: tint, padding: padding))
    }
}

/// A short colored label: symbol and text, no capsule, no capitals.
struct Pill: View {
    let text: String
    var symbol: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.legible(color))
    }
}

/// Session type: a small swatch in the color of its intensity, then the name.
struct TypePill: View {
    let kind: SessionType
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.color)
                .frame(width: 12, height: 8)
                .accessibilityHidden(true)
            Text(kind.label)
                .font(.caption.weight(.semibold))
        }
    }
}

/// Phase of a week ("Build", "Step-back") — plain text, it's context, not a status.
struct PhasePill: View {
    let phase: String
    var body: some View {
        Text(phase)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct VerdictPill: View {
    let verdict: Verdict
    var body: some View { Pill(text: verdict.label, symbol: verdict.symbol, color: verdict.color) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.leading, 2)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// Whole card clickable, with a subtle hover effect.
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
                .foregroundStyle(isDone ? AnyShapeStyle(.legible(.green)) : AnyShapeStyle(Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                // 28 × 28 pt: the default control size on the Mac; the bare symbol is only ~18 pt.
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as open (completed.json)" : "Mark as done (completed.json)")
        .accessibilityLabel(isDone ? "Mark as open" : "Mark as done")
    }
}

// MARK: - Zeilen

/// Content of a plan session (without the done button).
struct SessionRowContent: View {
    let session: PlannedSession
    let isDone: Bool
    var doneDate: String? = nil
    var hasRun = false
    var isDropped = false
    /// km of the linked run, once the session is done.
    var actualKm: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TypePill(kind: session.kind)
                if let actualKm {
                    // Run: what was run, then the plan.
                    Text("\(Text(Fmt.km(actualKm)).font(.figures(.callout))) \(Text("of \(session.dist)").foregroundStyle(.secondary))")
                } else {
                    Text(session.dist)
                        .font(.figures(.callout))
                        .strikethrough(isDropped, color: .secondary)
                        .foregroundStyle(isDropped ? .secondary : .primary)
                }
                if isDropped {
                    Text("Dropped").font(.caption).foregroundStyle(.secondary)
                }
                if hasRun {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Analysis available")
                }
            }
            Text(session.desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let doneDate {
                Text("Done on \(doneDate)")
                    .font(.caption)
                    .foregroundStyle(.legible(.green))
            }
        }
        // No dimming for finished sessions: 65 % opacity pushed the green date line to 2.8:1.
        // Done is shown by the check, the date and the run's distance.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunRow: View {
    let run: Run
    let label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if let day = run.day {
                    Text(Fmt.weekdayDayMonth(day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The verdict as a symbol with a label — not by color alone.
                if run.isAnalyzed, let verdict = run.verdict {
                    Image(systemName: verdict.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.legible(verdict.color))
                        .help(verdict.label)
                        .accessibilityLabel(verdict.label)
                }
                if !run.isAnalyzed {
                    Text("New")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.legible(.blue))
                        .help("Loaded, but not yet reviewed by the coach")
                }
                Spacer()
                Text("\(Fmt.km(run.distanceKm)) km")
                    .font(.figures(.callout))
            }
            Text(run.name)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text(label ?? run.tag ?? (run.isAnalyzed ? String(localized: "Unplanned") : String(localized: "Not assigned to a session yet")))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Fmt.pace(run.paceSeconds)) /km")
                if let hr = run.avgHr {
                    Text("\(Fmt.int(hr)) bpm")
                }
            }
            .font(.figures(.caption, weight: .regular))
            .foregroundStyle(.secondary)
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
        // The label says what it is; `symbol` stays for VoiceOver context only.
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.figures(.title3))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color)
                            .frame(width: geo.size.width * ratio)
                            .overlay(alignment: .leading) {
                                Text(Fmt.pace(split.paceS))
                                    .font(.figures(.caption))
                                    .foregroundStyle(.black.opacity(0.85))
                                    .padding(.leading, 6)
                            }
                    }
                    .frame(height: 20)
                    Group {
                        if let hr = split.hr, let zone {
                            Text("\(Fmt.int(hr)) bpm, Z\(zone)")
                        } else {
                            Text("")
                        }
                    }
                    .font(.figures(.caption, weight: .regular))
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

// MARK: - Flow layout (flags, legends)

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

// MARK: - Two columns when there's room

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

// MARK: - Error states

struct LoadErrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("No training data", systemImage: "folder.badge.questionmark")
        } description: {
            Text(model.loadError ?? String(localized: "The data could not be loaded."))
            Text(model.folder.url.path).font(.caption).foregroundStyle(.secondary)
        } actions: {
            HStack {
                Button("Open setup …") { openWindow(id: "setup") }
                    .buttonStyle(.borderedProminent)
                Button("Reload") { model.reload(force: true) }
                SettingsLink { Text("Change folder …") }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.legible(.orange))
            .card(tint: .orange, padding: 12)
    }
}
