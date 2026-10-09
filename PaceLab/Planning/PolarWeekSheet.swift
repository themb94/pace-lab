import AppKit
import SwiftUI

/// A workout from plan.json as Polar phases. Polar's phased training targets have a name, a length (time or
/// distance) and an intensity as a zone of the sport profile — the exact range is shown so the right zone
/// can be picked.
enum PolarPhases {
    struct Line: Hashable {
        let depth: Int
        let title: String
        let detail: String
        var note: String?
    }

    static func lines(_ steps: [WorkoutStep], bands: [PaceBand], snapshot: TrainingSnapshot, depth: Int = 0) -> [Line] {
        var lines: [Line] = []
        for step in steps {
            if let count = step.repeat, let inner = step.steps {
                lines.append(Line(depth: depth, title: String(localized: "Repeat \(count) ×"), detail: ""))
                lines += Self.lines(inner, bands: bands, snapshot: snapshot, depth: depth + 1)
            } else {
                let length = WorkoutText.describe(WorkoutStep.length(of: step), bands: bands)
                lines.append(Line(depth: depth, title: WorkoutText.typeLabel(step.type),
                                  detail: "\(length) · \(intensity(step, bands: bands, snapshot: snapshot))",
                                  note: step.note))
            }
        }
        return lines
    }

    static func intensity(_ step: WorkoutStep, bands: [PaceBand], snapshot: TrainingSnapshot) -> String {
        if let pace = step.pace {
            let range = (bands.first { $0.name.caseInsensitiveCompare(pace) == .orderedSame }?.range ?? pace)
                .replacingOccurrences(of: "-", with: "–")
            return String(localized: "pace zone for \(range)/km")
        }
        if let hr = step.hr {
            let bounds = hr.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let range = hr.replacingOccurrences(of: "-", with: "–")
            if bounds.count == 2 {
                return String(localized: "heart-rate zone \(snapshot.zone(forHR: (bounds[0] + bounds[1]) / 2)) (\(range) bpm)")
            }
            return String(localized: "heart rate \(range) bpm")
        }
        return String(localized: "free, by feel")
    }

    /// For the clipboard: name and phases, one per line.
    static func text(name: String, lines: [Line]) -> String {
        ([name] + lines.map { line in
            let pad = String(repeating: "   ", count: line.depth)
            let note = line.note.map { " — \($0)" } ?? ""
            return line.detail.isEmpty ? "\(pad)\(line.title)" : "\(pad)• \(line.title): \(line.detail)\(note)"
        }).joined(separator: "\n")
    }
}

private extension WorkoutStep {
    /// Only the length (for the text, without a target).
    static func length(of step: WorkoutStep) -> WorkoutStep {
        var copy = step
        copy.pace = nil
        copy.hr = nil
        return copy
    }
}

/// A week's workouts for a Polar watch. Polar doesn't let other apps put training targets on the watch,
/// so they are entered by hand in Polar Flow — this sheet shows exactly what to enter.
struct PolarWeekSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let week: Int
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Week \(week) for Polar", systemImage: "applewatch")
                .font(.title2.bold())
            Text("Polar doesn’t let other apps put workouts on the watch. Create each session as a phased training target — in the Polar Flow app (Training targets › +) or at flow.polar.com (Diary › Add › Training target › Phased) — and then sync the watch.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.sessions(inWeek: week)) { session in
                            card(session, snapshot: snapshot)
                        }
                    }
                }
                .frame(maxHeight: 470)
            }
            Text("Polar phases use the zones of the sport profile: pick the heart-rate or pace zone that fits the range shown, or adjust the zones in the sport profile once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(destination: URL(string: "https://flow.polar.com/diary")!) {
                    Label("Open Polar Flow", systemImage: "arrow.up.right.square")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func card(_ session: PlannedSession, snapshot: TrainingSnapshot) -> some View {
        let bands = snapshot.plan.paceBands ?? []
        let name = session.garminName ?? "\(session.kind.label) \(session.dist)"
        let lines = session.workout.map { PolarPhases.lines($0.steps, bands: bands, snapshot: snapshot) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TypePill(kind: session.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).textSelection(.enabled)
                    Text(session.desc).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isUploadable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PolarPhases.text(name: name, lines: lines), forType: .string)
                        copied = session.id
                    } label: {
                        Label(copied == session.id ? String(localized: "Copied") : String(localized: "Copy"),
                              systemImage: copied == session.id ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
            if !session.isUploadable {
                Text(session.kind == .easy ? "Easy runs are not entered as a target — run by feel." : "No workout in plan.json.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(line.title).foregroundStyle(line.detail.isEmpty ? Color.brand : .secondary)
                                    .fontWeight(line.detail.isEmpty ? .bold : .regular)
                                if !line.detail.isEmpty {
                                    Text(line.detail).monospacedDigit()
                                }
                            }
                            if let note = line.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, CGFloat(line.depth) * 16)
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .opacity(session.isUploadable ? 1 : 0.55)
        .card(padding: 14)
    }
}
