import SwiftUI

struct RunsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                split(snapshot)
            } else {
                LoadErrorView()
            }
        }
        .navigationTitle("Läufe")
        .searchable(text: $query, placement: .toolbar, prompt: "Name, Tag, Analyse …")
    }

    private func split(_ snapshot: TrainingSnapshot) -> some View {
        @Bindable var model = model
        let runs = filtered(snapshot)
        return HSplitView {
            List(selection: $model.selectedRunID) {
                if query.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            MetricTile(value: "\(snapshot.runs.count)", label: "Läufe", symbol: "figure.run")
                            MetricTile(value: Fmt.km(snapshot.totalKm, digits: 0), label: "km", symbol: "ruler")
                            MetricTile(value: "\(snapshot.runs.filter { $0.verdict == .gut }.count)", label: "gut", symbol: "checkmark.seal")
                        }
                        .selectionDisabled()
                    }
                }
                ForEach(monthGroups(runs), id: \.key) { group in
                    Section(group.title) {
                        ForEach(group.runs) { run in
                            RunRow(run: run, label: snapshot.label(for: run))
                                .tag(run.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if runs.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Noch keine Läufe", systemImage: "figure.run",
                                               description: Text("Nach der Wochenauswertung erscheinen hier deine analysierten Läufe."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 480)

            Group {
                if let id = model.selectedRunID, let run = snapshot.run(id: id) {
                    RunDetailView(run: run, snapshot: snapshot)
                } else {
                    ContentUnavailableView("Lauf auswählen", systemImage: "figure.run",
                                           description: Text("Wähle links einen Lauf, um Splits und Analyse zu sehen."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.pageBackground)
        }
        .onAppear {
            if model.selectedRunID == nil { model.selectedRunID = snapshot.runs.first?.id }
        }
    }

    private func filtered(_ snapshot: TrainingSnapshot) -> [Run] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snapshot.runs }
        return snapshot.runs.filter { run in
            [run.name, run.tag, run.analysis, snapshot.label(for: run), run.flags?.joined(separator: " ")]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(q) }
        }
    }

    private struct MonthGroup {
        let key: String
        let title: String
        let runs: [Run]
    }

    private func monthGroups(_ runs: [Run]) -> [MonthGroup] {
        var order: [String] = []
        var byMonth: [String: [Run]] = [:]
        for run in runs {
            let key = String(run.date.prefix(7))
            if byMonth[key] == nil { order.append(key) }
            byMonth[key, default: []].append(run)
        }
        return order.map { key in
            let title = DateUtil.day(fromISO: key + "-01").map(Fmt.monthYear) ?? key
            return MonthGroup(key: key, title: title, runs: byMonth[key] ?? [])
        }
    }
}
