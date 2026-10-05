import SwiftUI

/// Formular „Mit dem Coach planen“: Woche anpassen, Einheit ändern oder neuen Block entwerfen.
struct PlanRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var request: PlanRequest

    init(request: PlanRequest) {
        _request = State(initialValue: request)
    }

    var body: some View {
        let engine = model.coach.activeEngine
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Plan with the coach", systemImage: "wand.and.stars")
                    .font(.title2.bold())
                Text("The coach (\(model.models.summary(for: engine))) plans according to the README and your reviews. You’ll see the result in the plan afterwards and can undo it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)

            Form {
                Picker("What", selection: $request.kind) {
                    ForEach(PlanRequest.Kind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let snapshot = model.snapshot {
                    switch request.kind {
                    case .week: weekFields(snapshot)
                    case .session: sessionFields(snapshot)
                    case .block: blockFields
                    }
                }

                if !engine.kind.isAgent {
                    Label("\(engine.name) can’t change files: the suggestion comes as JSON and the app only applies it once you agree.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.submit(request)
                } label: {
                    Label("Let the coach plan", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .keyboardShortcut(.defaultAction)
                .disabled(model.coach.isRunning || model.sync.isRunning || (request.kind == .session && request.sessionID == nil))
            }
            .padding(20)
        }
        .frame(width: 600)
        .frame(minHeight: 460)
    }

    private var footnote: String {
        switch request.kind {
        case .week, .session: String(localized: "Changes plan.json — it only reaches the watch when you upload it.")
        case .block: String(localized: "Saved as a draft; the current block keeps running until you apply it.")
        }
    }

    @ViewBuilder
    private func weekFields(_ snapshot: TrainingSnapshot) -> some View {
        Section {
            Picker("Week", selection: $request.week) {
                ForEach(1...snapshot.weekCount, id: \.self) { week in
                    Text("Week \(week) · \(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))) · \(snapshot.phase(ofWeek: week))")
                        .tag(week)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.sessions(inWeek: request.week)) { session in
                    HStack(spacing: 6) {
                        TypePill(kind: session.kind)
                        Text("\(session.dist) · \(session.desc)")
                            .lineLimit(1)
                            .foregroundStyle(snapshot.isDone(session) ? .secondary : .primary)
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 2)
        }
        Section("What’s going on?") {
            TextField("Reason", text: $request.details,
                      prompt: Text("e.g. “city run on Saturday”, “knee is sore”, “only 2 days available” — leave empty for a check-in"),
                      axis: .vertical)
                .lineLimit(3...6)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func sessionFields(_ snapshot: TrainingSnapshot) -> some View {
        Section {
            Picker("Session", selection: $request.sessionID) {
                Text("Please choose").tag(String?.none)
                ForEach(1...snapshot.weekCount, id: \.self) { week in
                    ForEach(snapshot.sessions(inWeek: week)) { session in
                        Text("W\(week) · \(session.kind.label) \(session.dist) — \(session.desc)").tag(Optional(session.id))
                    }
                }
            }
        }
        Section("What should be different?") {
            TextField("Request", text: $request.details,
                      prompt: Text("e.g. “5×1000 m instead of 6×800 m”, “move to Sunday, only 10 km”"),
                      axis: .vertical)
                .lineLimit(3...6)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var blockFields: some View {
        Section("Goal") {
            TextField("Goal", text: $request.goal, prompt: Text("e.g. “10 km under 55 min” or “half marathon in spring”"))
            Toggle("Target race", isOn: $request.hasRace)
            if request.hasRace {
                DatePicker("Race day", selection: $request.raceDate, displayedComponents: .date)
            }
        }
        Section("Parameters") {
            DatePicker("Start (Monday)", selection: $request.start, displayedComponents: .date)
            Stepper("\(request.weeks) weeks", value: $request.weeks, in: 4...24)
            Stepper("\(request.runsPerWeek) runs per week", value: $request.runsPerWeek, in: 2...6)
        }
        Section("Special considerations") {
            TextField("Special considerations", text: $request.details,
                      prompt: Text("e.g. holidays, races, wishes for the structure"), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
        }
    }
}
