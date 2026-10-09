import SwiftUI

/// Details of a plan session (right-hand inspector in the plan).
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: PlannedSession
    let snapshot: TrainingSnapshot

    var body: some View {
        let isDone = snapshot.isDone(session)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TypePill(kind: session.kind)
                        PhasePill(phase: session.phase)
                    }
                    Text(session.dist)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(session.desc)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(
                        String(localized: "Week \(session.week) · \(Fmt.range(snapshot.monday(ofWeek: session.week), snapshot.sunday(ofWeek: session.week)))")
                            + (session.weekNote.map { " · \($0)" } ?? ""),
                        systemImage: "calendar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .card(tint: session.kind.color)

                if let workout = session.workout {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Workout")
                        VStack(alignment: .leading, spacing: 10) {
                            WorkoutStepsView(workout: workout, bands: snapshot.plan.paceBands ?? [])
                            Divider()
                            Label(watchNote(session, workout: workout), systemImage: "applewatch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card(padding: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(isDone ? (snapshot.doneDate(session).map { "Done on \($0)" } ?? "Done") : "Still open")
                    } icon: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(isDone ? .green : .secondary)
                    }
                    .font(.headline)

                    Button {
                        withAnimation { model.toggleDone(session) }
                    } label: {
                        Label(isDone ? "Mark as open" : "Mark as done",
                              systemImage: isDone ? "arrow.uturn.backward" : "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isDone ? .gray : .green)
                    .controlSize(.large)

                    Text("Writes straight to completed.json — the coach sees it too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .card()

                VStack(spacing: 8) {
                    Button {
                        model.requestPlan(.session, session: session)
                    } label: {
                        Label("Change with coach …", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.coach.isRunning)
                    if session.isUploadable && model.watch != .none {
                        Button {
                            model.watchWeek = session.week
                        } label: {
                            Label(model.watch == .polar ? String(localized: "Week \(session.week) for Polar …")
                                                        : String(localized: "Create week \(session.week) on Garmin …"),
                                  systemImage: "applewatch")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .controlSize(.large)

                if let run = snapshot.linkedRun(for: session) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Actual run"))
                        Button { model.show(run) } label: {
                            RunRow(run: run, label: snapshot.label(for: run)).card(padding: 12)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }

                if session.kind == .tempo, let bands = snapshot.plan.paceBands, !bands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Pace bands"))
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(bands, id: \.self) { band in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(band.name)
                                    Spacer()
                                    Text("\(band.range) /km").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            Text("Warm-up, cool-down and jog breaks have no target. On warm days (>25 °C) cap heart rate rather than chase pace.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card(padding: 14)
                    }
                }

                if let summary = snapshot.summary(forWeek: session.week), let analysis = summary.analysis {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: String(localized: "Week summary"))
                        Text(analysis).font(.callout).card(padding: 14)
                    }
                }
            }
            .padding(16)
        }
    }

    /// What happens with the workout on the profile's watch.
    private func watchNote(_ session: PlannedSession, workout: PlanWorkout) -> String {
        guard session.isUploadable else { return String(localized: "Easy runs are not sent to the watch — run by feel.") }
        let name = session.garminName ?? workout.name
        switch model.watch {
        case .garmin: return String(localized: "On the watch as “\(name)”")
        case .polar: return String(localized: "For Polar as phased training target “\(name)”")
        case .none: return String(localized: "No watch connected — the steps are your guide.")
        }
    }
}
