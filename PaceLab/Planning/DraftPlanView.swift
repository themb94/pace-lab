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
                            Text("Woche \(week)").font(.headline).foregroundStyle(.primary)
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
                Section("Pace-Bänder") {
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
        .confirmationDialog("„\(draft.title)“ übernehmen?", isPresented: $confirmApply) {
            Button("Übernehmen") { model.applyDraft() }
        } message: {
            Text(applyMessage)
        }
        .confirmationDialog("Entwurf verwerfen?", isPresented: $confirmDiscard) {
            Button("Verwerfen", role: .destructive) { model.discardDraft() }
        } message: {
            Text("plan-entwurf.json wird gelöscht. Im Verlauf bleibt er erhalten.")
        }
    }

    private var applyMessage: String {
        var text = "Der Entwurf wird zum aktiven Plan. Der bisherige Plan wird unter plans/ abgelegt; Häkchen und Analysen bleiben erhalten."
        if let current = model.snapshot, case .running(let week) = current.status(on: .now) {
            text = "Achtung: „\(current.plan.title)“ läuft noch (Woche \(week) von \(current.weekCount)). " + text
        }
        return text
    }

    private func header(_ snapshot: TrainingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(text: "ENTWURF", symbol: "pencil.and.list.clipboard", color: .purple)
                if let prefix = draft.idPrefix {
                    Text("ID-Präfix \(prefix) · Workouts \(draft.workoutPrefix ?? prefix.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(draft.title).font(.title.bold())
            if let goal = draft.goal { Text(goal).font(.title3).foregroundStyle(Color.brand) }
            Text("\(snapshot.weekCount) Wochen ab \(Fmt.longDate(snapshot.startMonday))")
                .foregroundStyle(.secondary)
            if let subtitle = draft.subtitle, !subtitle.contains("\(snapshot.weekCount) Wochen") {
                Text(subtitle).foregroundStyle(.secondary)
            }
            if let previous = draft.previous {
                Text(previous).font(.callout).foregroundStyle(.secondary)
            }
            if draft.idPrefix == model.snapshot?.plan.idPrefix {
                Label("Gleiches ID-Präfix wie der aktuelle Block — so kann der Entwurf nicht übernommen werden.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    confirmApply = true
                } label: {
                    Label("Als aktiven Plan übernehmen", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .disabled(draft.idPrefix == model.snapshot?.plan.idPrefix)

                Button {
                    model.coach.newConversation()
                    model.coach.draft = "Überarbeite den Entwurf in plan-entwurf.json: "
                    model.section = .coach
                } label: {
                    Label("Mit Coach überarbeiten", systemImage: "sparkles")
                }

                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Verwerfen", systemImage: "trash")
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .card(tint: .purple)
        .padding(.vertical, 6)
    }
}
