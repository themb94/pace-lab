import SwiftUI

/// Entwurf für einen neuen Block (plan-entwurf.json) — ansehen, übernehmen oder verwerfen.
struct DraftPlanView: View {
    @Environment(AppModel.self) private var model
    let draft: TrainingPlan

    @State private var confirmApply = false
    @State private var confirmDiscard = false

    var body: some View {
        let snapshot = TrainingSnapshot(plan: draft, analysis: AnalysisFile(runs: [], weekSummaries: nil), completed: [:])
        List {
            Section {
                header(snapshot)
                    .selectionDisabled()
            }
            ForEach(1...max(snapshot.weekCount, 1), id: \.self) { week in
                if week <= snapshot.weekCount {
                    Section {
                        ForEach(snapshot.sessions(inWeek: week)) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                SessionRowContent(session: session, isDone: false)
                                if let workout = session.workout {
                                    WorkoutStepsView(workout: workout, bands: draft.paceBands ?? [], compact: true)
                                        .padding(.leading, 4)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text("Week \(week)").font(.headline).foregroundStyle(.primary)
                            PhasePill(phase: snapshot.phase(ofWeek: week))
                            Text(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))
                                 + (snapshot.note(ofWeek: week).map { " · \($0)" } ?? ""))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Fmt.km(snapshot.plannedKm(week: week), digits: 0)) km").foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    }
                }
            }
            if let bands = draft.paceBands, !bands.isEmpty {
                Section("Pace bands") {
                    ForEach(bands, id: \.self) { band in
                        HStack {
                            Text(band.name)
                            Spacer()
                            Text("\(band.range) /km").monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog("Apply “\(draft.title)”?", isPresented: $confirmApply) {
            Button("Apply") { model.applyDraft() }
        } message: {
            Text(applyMessage)
        }
        .confirmationDialog("Discard draft?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { model.discardDraft() }
        } message: {
            Text("plan-entwurf.json will be deleted. It stays available in the history.")
        }
    }

    private var applyMessage: String {
        var text = String(localized: "The draft becomes the active plan. The previous plan is saved under plans/; ticks and analyses are kept.")
        if let current = model.snapshot, case .running(let week) = current.status(on: .now) {
            text = String(localized: "Heads up: “\(current.plan.title)” is still running (week \(week) of \(current.weekCount)). ") + text
        }
        return text
    }

    private func header(_ snapshot: TrainingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(text: String(localized: "DRAFT"), symbol: "pencil.and.list.clipboard", color: .purple)
                if let prefix = draft.idPrefix {
                    Text("ID prefix \(prefix) · Workouts \(draft.workoutPrefix ?? prefix.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(draft.title).font(.title.bold())
            if let goal = draft.goal { Text(goal).font(.title3).foregroundStyle(Color.brand) }
            Text("\(snapshot.weekCount) weeks starting \(Fmt.longDate(snapshot.startMonday))")
                .foregroundStyle(.secondary)
            if let subtitle = draft.subtitle, !subtitle.contains("\(snapshot.weekCount) Wochen"), !subtitle.contains("\(snapshot.weekCount) weeks") {
                Text(subtitle).foregroundStyle(.secondary)
            }
            if let previous = draft.previous {
                Text(previous).font(.callout).foregroundStyle(.secondary)
            }
            if draft.idPrefix == model.snapshot?.plan.idPrefix {
                Label("Same ID prefix as the current block — the draft can’t be applied like this.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    confirmApply = true
                } label: {
                    Label("Apply as active plan", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .disabled(draft.idPrefix == model.snapshot?.plan.idPrefix)

                Button {
                    model.coach.newConversation()
                    model.coach.draft = String(localized: "Revise the draft in plan-entwurf.json: ")
                    model.section = .coach
                } label: {
                    Label("Revise with coach", systemImage: "sparkles")
                }

                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard", systemImage: "trash")
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .card(tint: .purple)
        .padding(.vertical, 6)
    }
}
