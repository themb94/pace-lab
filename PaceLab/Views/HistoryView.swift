import SwiftUI

/// Alle festgehaltenen Stände des Trainingsordners (git) — mit Änderungen und „Rückgängig“.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ProjectHistory.Entry] = []
    @State private var selection: ProjectHistory.Entry.ID?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var settingUp = false
    /// Offene Rückfrage: nil = ganzer Verlauf, sonst Stände älter als so viele Tage.
    @State private var deleteRequest: DeleteRequest?
    @State private var deleting = false

    private struct DeleteRequest: Identifiable {
        let days: Int?
        var id: Int { days ?? 0 }
    }

    var body: some View {
        Group {
            if !model.history.isRepository {
                setUpView
            } else if loaded && entries.isEmpty {
                ContentUnavailableView("Noch keine Stände", systemImage: "clock.arrow.circlepath",
                                       description: Text(loadError ?? "Sobald du etwas abhakst, Läufe lädst oder der Coach arbeitet, erscheint es hier."))
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.entries) { entry in
                                    HistoryRow(entry: entry).tag(entry.id)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)

                    Group {
                        if let entry = entries.first(where: { $0.id == selection }) {
                            HistoryDetail(entry: entry, isLatest: entry.id == entries.first?.id)
                                .id(entry.id)
                        } else {
                            ContentUnavailableView("Stand auswählen", systemImage: "clock.arrow.circlepath",
                                                   description: Text("Links einen Stand wählen, um die Änderungen zu sehen."))
                        }
                    }
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.pageBackground)
                }
            }
        }
        .navigationTitle("Verlauf")
        .navigationSubtitle(entries.isEmpty ? "" : "\(entries.count) Stände")
        .task(id: model.historyRevision) { await load() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Stände älter als 7 Tage löschen …") { deleteRequest = DeleteRequest(days: 7) }
                    Button("Stände älter als 30 Tage löschen …") { deleteRequest = DeleteRequest(days: 30) }
                    Divider()
                    Button("Gesamten Verlauf löschen …", role: .destructive) { deleteRequest = DeleteRequest(days: nil) }
                } label: {
                    Label("Verlauf löschen", systemImage: "trash")
                }
                .help("Alte Stände oder den ganzen Verlauf löschen — deine Dateien bleiben unverändert")
                .disabled(!model.history.isRepository || entries.count < 2 || deleting
                          || model.coach.isRunning || model.sync.isRunning)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }),
                            presenting: deleteRequest) { request in
            Button(request.days == nil ? "Verlauf löschen" : "Ältere Stände löschen", role: .destructive) {
                deleting = true
                Task {
                    await model.deleteHistory(olderThan: request.days)
                    deleting = false
                }
            }
        } message: { request in
            Text(deleteMessage(request))
        }
        .overlay {
            if deleting {
                ProgressView("Lösche …")
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var deleteTitle: String {
        guard let request = deleteRequest else { return "" }
        return request.days.map { "Stände älter als \($0) Tage löschen?" } ?? "Gesamten Verlauf löschen?"
    }

    private func deleteMessage(_ request: DeleteRequest) -> String {
        let keep = "Deine Dateien — Plan, Läufe, Häkchen — bleiben genau so, wie sie jetzt sind. Gelöschte Stände sind endgültig weg und lassen sich nicht mehr zurücknehmen."
        guard let days = request.days else {
            return "Alle \(entries.count) Stände werden gelöscht; der jetzige Stand wird der neue Ausgangspunkt. " + keep
        }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let older = entries.filter { $0.date < cutoff }.count
        guard older > 0 else { return "Es gibt keine Stände vor dem \(Fmt.dayMonth(cutoff)) — es passiert nichts." }
        return "\(older) Stände vor dem \(Fmt.dayMonth(cutoff)) werden gelöscht; alles danach bleibt mit „Rückgängig“ erhalten. " + keep
    }

    private var setUpView: some View {
        ContentUnavailableView {
            Label("Versionsverwaltung ist aus", systemImage: "clock.badge.questionmark")
        } description: {
            Text("Mit git hält die App jede Änderung am Trainingsordner als Stand fest — vom Coach, von Häkchen und geladenen Läufen — und kann sie rückgängig machen.")
        } actions: {
            Button {
                settingUp = true
                Task {
                    do { try await model.setUpHistory() } catch { loadError = error.localizedDescription }
                    settingUp = false
                }
            } label: {
                Label("Einrichten", systemImage: "checkmark.circle")
            }
            .disabled(settingUp)
            if let loadError { Text(loadError).foregroundStyle(.orange) }
        }
    }

    private func load() async {
        do {
            entries = try await model.history.log()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
        if selection == nil || !entries.contains(where: { $0.id == selection }) {
            selection = entries.first?.id
        }
    }

    private struct Group_: Identifiable {
        let title: String
        let entries: [ProjectHistory.Entry]
        var id: String { title }
    }

    /// Nach Tagen gruppiert: „Heute“, „Gestern“, „Mittwoch, 23. September“.
    private var groups: [Group_] {
        var result: [Group_] = []
        for entry in entries {
            let title = dayTitle(entry.date)
            if let last = result.last, last.title == title {
                result[result.count - 1] = Group_(title: title, entries: last.entries + [entry])
            } else {
                result.append(Group_(title: title, entries: [entry]))
            }
        }
        return result
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = DateUtil.calendar
        if cal.isDateInToday(date) { return "Heute" }
        if cal.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.de))
    }
}

private struct HistoryRow: View {
    let entry: ProjectHistory.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: HistoryStyle.symbol(for: entry.subject))
                .foregroundStyle(HistoryStyle.color(for: entry.subject))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.subject)
                HStack(spacing: 6) {
                    Text(entry.date.formatted(.dateTime.hour().minute().locale(Fmt.de)))
                    Text(entry.files.map { ($0.path as NSString).lastPathComponent }.prefix(3).joined(separator: ", ")
                         + (entry.files.count > 3 ? " +\(entry.files.count - 3)" : ""))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

enum HistoryStyle {
    static func symbol(for subject: String) -> String {
        switch true {
        case subject.hasPrefix("Coach"): "sparkles"
        case subject.hasPrefix("Abgehakt"): "checkmark.circle"
        case subject.hasPrefix("Häkchen"): "circle"
        case subject.contains("geladen"): "figure.run"
        case subject.hasPrefix("Zugeordnet"): "link"
        case subject.hasPrefix("Rückgängig"): "arrow.uturn.backward"
        case subject.hasPrefix("Neuer Block"), subject.hasPrefix("Entwurf"), subject.hasPrefix("Vorschlag"): "calendar"
        case subject.hasPrefix("Ausgangsstand"): "flag"
        case subject.hasPrefix(ProjectHistory.externalChanges): "pencil"
        default: "circle.dashed"
        }
    }

    static func color(for subject: String) -> Color {
        switch true {
        case subject.hasPrefix("Coach"): .brand
        case subject.hasPrefix("Abgehakt"): .green
        case subject.contains("geladen"): .blue
        case subject.hasPrefix("Rückgängig"): .orange
        case subject.hasPrefix("Neuer Block"), subject.hasPrefix("Entwurf"), subject.hasPrefix("Vorschlag"): .purple
        default: .secondary
        }
    }
}

private struct HistoryDetail: View {
    @Environment(AppModel.self) private var model
    let entry: ProjectHistory.Entry
    let isLatest: Bool

    @State private var diff: [DiffLine] = []
    @State private var truncated = false
    @State private var confirmRevert = false
    @State private var conflict = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Fmt.de)))
                        .foregroundStyle(.secondary)
                    Label {
                        Text(entry.subject).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: HistoryStyle.symbol(for: entry.subject))
                            .foregroundStyle(HistoryStyle.color(for: entry.subject))
                    }
                    if !entry.body.isEmpty {
                        Text(entry.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                    HStack {
                        if entry.canRevert {
                            Button {
                                confirmRevert = true
                            } label: {
                                Label("Diese Änderung rückgängig machen", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(working || model.coach.isRunning || model.sync.isRunning)
                        }
                        if working { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(entry.shortID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Geänderte Dateien")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.files, id: \.path) { file in
                            HStack {
                                Text(file.path).font(.callout.monospaced())
                                Spacer()
                                if let added = file.added, let removed = file.removed {
                                    Text("+\(added)").foregroundStyle(.green)
                                    Text("−\(removed)").foregroundStyle(.red)
                                }
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                    .card(padding: 12)
                }

                if entry.canRevert {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "Änderungen")
                        DiffView(lines: diff, truncated: truncated)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .task { await loadDiff() }
        .confirmationDialog("„\(entry.subject)“ rückgängig machen?", isPresented: $confirmRevert) {
            Button("Rückgängig machen") { Task { await revert() } }
        } message: {
            Text(isLatest
                 ? "Die Dateien kommen auf den Stand davor. Das wird selbst als neuer Stand festgehalten."
                 : "Nur diese Änderungen werden zurückgenommen, spätere bleiben erhalten. Das wird selbst als neuer Stand festgehalten.")
        }
        .alert("Geht nicht automatisch", isPresented: $conflict) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Spätere Änderungen betreffen dieselben Stellen. Nimm zuerst die späteren Stände zurück oder bitte den Coach, es von Hand zu korrigieren.")
        }
    }

    private func loadDiff() async {
        guard entry.canRevert, let text = try? await model.history.diff(of: entry.id) else { return }
        let limit = 4_000
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        truncated = all.count > limit
        diff = all.prefix(limit).compactMap(DiffLine.init)
    }

    private func revert() async {
        working = true
        let outcome = await model.revert(entry)
        working = false
        if case .conflict = outcome { conflict = true }
    }
}

/// Eine Zeile eines unified diff, fürs Einfärben.
struct DiffLine: Identifiable {
    enum Kind { case file, hunk, added, removed, context }

    let id = UUID()
    let kind: Kind
    let text: String

    init?(_ raw: Substring) {
        if raw.hasPrefix("diff --git ") {
            kind = .file
            text = raw.split(separator: " b/", maxSplits: 1).last.map(String.init) ?? String(raw)
        } else if raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ")
                    || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") || raw.hasPrefix("\\ ") {
            return nil
        } else if raw.hasPrefix("@@") {
            kind = .hunk
            text = String(raw)
        } else if raw.hasPrefix("+") {
            kind = .added
            text = String(raw)
        } else if raw.hasPrefix("-") {
            kind = .removed
            text = String(raw)
        } else {
            kind = .context
            text = String(raw)
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]
    var truncated = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                switch line.kind {
                case .file:
                    Text(line.text)
                        .font(.callout.weight(.semibold))
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 8)
                case .hunk:
                    Text(line.text)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.07))
                default:
                    Text(line.text.isEmpty ? " " : line.text)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                }
            }
            if truncated {
                Text("… gekürzt")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .card(padding: 6)
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.12)
        default: .clear
        }
    }
}
