import SwiftUI

/// The steps of a workout from plan.json, e.g. "Warm-up · 10 min", "6 ×", "Interval · 800 m @ 4:45–5:15".
struct WorkoutStepsView: View {
    let workout: PlanWorkout
    let bands: [PaceBand]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            steps(workout.steps, depth: 0)
        }
    }

    private func steps(_ steps: [WorkoutStep], depth: Int) -> AnyView {
        AnyView(ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            if let count = step.repeat, let inner = step.steps {
                VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                    Text("\(count) ×")
                        .font((compact ? Font.caption : .callout).weight(.bold))
                        .foregroundStyle(Color.brand)
                    self.steps(inner, depth: depth + 1)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(Color.brand.opacity(0.35)).frame(width: 2)
                        }
                }
            } else {
                row(step)
            }
        })
    }

    private func row(_ step: WorkoutStep) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(color(step.type))
                    .frame(width: 7, height: 7)
                Text(WorkoutText.typeLabel(step.type))
                    .foregroundStyle(.secondary)
                Text(WorkoutText.describe(step, bands: bands))
                    .fontWeight(step.pace != nil ? .semibold : .regular)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if !compact, let note = step.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(compact ? .caption : .callout)
    }

    private func color(_ type: String?) -> Color {
        switch type {
        case "interval": .brand
        case "recovery", "rest": .green
        case "warmup", "cooldown": .blue
        default: .gray
        }
    }
}
