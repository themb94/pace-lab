import SwiftUI

// The app's one visual idea: every session is a bar. Length = distance, color = intensity (heart-rate
// zone of the session type), form = state. The same grammar runs through the block (one row per week),
// the week (one bar per session) and a run (one bar per split).

/// One session as a bar: filled = run, dashed outline = planned, dotted and struck through = dropped.
struct EffortBar: View {
    let kind: SessionType
    let state: SessionState
    var label: String? = nil
    var height: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack(alignment: .leading) {
            switch state {
            case .done:
                shape.fill(kind.color)
            case .open:
                shape.strokeBorder(kind.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            case .dropped:
                shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2.5]))
                Rectangle().fill(Color.secondary).frame(height: 1.5).padding(.horizontal, 3)
            }
            if let label, state != .dropped {
                Text(label)
                    .font(.figures(.caption2))
                    .foregroundStyle(state == .done ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .padding(.leading, 5)
            }
        }
        .frame(height: height)
        .clipShape(shape)
    }
}

/// The sessions of one week side by side, each as wide as its distance (relative to `scaleKm`).
struct WeekBars: View {
    let snapshot: TrainingSnapshot
    let week: Int
    /// km that fill the whole width — usually the longest week of the block.
    let scaleKm: Double
    var height: CGFloat = 18
    var showLabels = true
    var onSelect: ((PlannedSession) -> Void)? = nil

    private let spacing: CGFloat = 3

    var body: some View {
        let sessions = snapshot.sessions(inWeek: week)
        GeometryReader { geo in
            let usable = max(geo.size.width - spacing * CGFloat(max(sessions.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(sessions) { session in
                    let km = snapshot.barKm(for: session)
                    let width = max(usable * min(km / max(scaleKm, 1), 1), 6)
                    bar(session, km: km)
                        .frame(width: width)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func bar(_ session: PlannedSession, km: Double) -> some View {
        let state = snapshot.state(of: session)
        let view = EffortBar(kind: session.kind, state: state,
                             label: showLabels ? Fmt.km(km, digits: 0) : nil, height: height)
            .help(Self.description(session, km: km, state: state))
            .accessibilityElement()
            .accessibilityLabel(Self.description(session, km: km, state: state))
        if let onSelect {
            Button { onSelect(session) } label: { view.contentShape(.rect) }
                .buttonStyle(.plain)
        } else {
            view
        }
    }

    static func description(_ session: PlannedSession, km: Double, state: SessionState) -> String {
        let status = switch state {
        case .done: String(localized: "done")
        case .open: String(localized: "planned")
        case .dropped: String(localized: "dropped")
        }
        return "\(session.kind.label), \(Fmt.km(km)) km, \(status)"
    }
}
