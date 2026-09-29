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
                Label("Mit dem Coach planen", systemImage: "wand.and.stars")
                    .font(.title2.bold())
                Text("Der Coach (\(model.models.summary(for: engine))) plant nach README und deinen Auswertungen. Du siehst das Ergebnis danach im Plan und kannst es rückgängig machen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)

            Form {
                Picker("Was", selection: $request.kind) {
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
                    Label("\(engine.name) kann keine Dateien ändern: Der Vorschlag kommt als JSON, die App übernimmt ihn erst, wenn du zustimmst.",
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
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.submit(request)
                } label: {
                    Label("Coach planen lassen", systemImage: "sparkles")
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
        case .week, .session: "Ändert plan.json — auf die Uhr kommt es erst, wenn du es hochlädst."
        case .block: "Wird als Entwurf abgelegt; der aktuelle Block läuft weiter, bis du übernimmst."
        }
    }

    @ViewBuilder
    private func weekFields(_ snapshot: TrainingSnapshot) -> some View {
        Section {
            Picker("Woche", selection: $request.week) {
                ForEach(1...snapshot.weekCount, id: \.self) { week in
                    Text("Woche \(week) · \(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))) · \(snapshot.phase(ofWeek: week))")
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
        Section("Was ist los?") {
            TextField("Anlass", text: $request.details,
                      prompt: Text("z. B. „Stadtlauf am Samstag“, „Knie zwickt“, „nur 2 Tage Zeit“ — leer lassen für einen Check"),
                      axis: .vertical)
                .lineLimit(3...6)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func sessionFields(_ snapshot: TrainingSnapshot) -> some View {
        Section {
            Picker("Einheit", selection: $request.sessionID) {
                Text("Bitte wählen").tag(String?.none)
                ForEach(1...snapshot.weekCount, id: \.self) { week in
                    ForEach(snapshot.sessions(inWeek: week)) { session in
                        Text("W\(week) · \(session.kind.label) \(session.dist) — \(session.desc)").tag(Optional(session.id))
                    }
                }
            }
        }
        Section("Was soll anders sein?") {
            TextField("Wunsch", text: $request.details,
                      prompt: Text("z. B. „lieber 5×1000 m statt 6×800 m“, „auf Sonntag verschieben, nur 10 km“"),
                      axis: .vertical)
                .lineLimit(3...6)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var blockFields: some View {
        Section("Ziel") {
            TextField("Ziel", text: $request.goal, prompt: Text("z. B. „10 km unter 55 min“ oder „HM Sub-2:00 im Frühjahr“"))
            Toggle("Zielrennen", isOn: $request.hasRace)
            if request.hasRace {
                DatePicker("Renntag", selection: $request.raceDate, displayedComponents: .date)
            }
        }
        Section("Rahmen") {
            DatePicker("Start (Montag)", selection: $request.start, displayedComponents: .date)
            Stepper("\(request.weeks) Wochen", value: $request.weeks, in: 4...24)
            Stepper("\(request.runsPerWeek) Läufe pro Woche", value: $request.runsPerWeek, in: 2...6)
        }
        Section("Besonderheiten") {
            TextField("Besonderheiten", text: $request.details,
                      prompt: Text("z. B. Urlaub, Wettkämpfe, Wünsche zur Struktur"), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
        }
    }
}
