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
                ContentUnavailableView("No versions yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(loadError ?? String(localized: "As soon as you tick something off, load runs or the coach works, it shows up here.")))
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
                            ContentUnavailableView("Select a version", systemImage: "clock.arrow.circlepath",
                                                   description: Text("Choose a version on the left to see the changes."))
                        }
                    }
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.pageBackground)
                }
            }
        }
        .navigationTitle("History")
        .navigationSubtitle(entries.isEmpty ? "" : "\(entries.count) versions")
        .task(id: model.historyRevision) { await load() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Delete versions older than 7 days …") { deleteRequest = DeleteRequest(days: 7) }
                    Button("Delete versions older than 30 days …") { deleteRequest = DeleteRequest(days: 30) }
                    Divider()
                    Button("Delete entire history …", role: .destructive) { deleteRequest = DeleteRequest(days: nil) }
                } label: {
                    Label("Delete history", systemImage: "trash")
                }
                .help("Delete old versions or the whole history — your files stay unchanged")
                .disabled(!model.history.isRepository || entries.count < 2 || deleting
                          || model.coach.isRunning || model.sync.isRunning)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }),
                            presenting: deleteRequest) { request in
            Button(request.days == nil ? "Delete history" : "Delete older versions", role: .destructive) {
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
                ProgressView("Deleting …")
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var deleteTitle: String {
        guard let request = deleteRequest else { return "" }
        return request.days.map { String(localized: "Delete versions older than \($0) days?") } ?? String(localized: "Delete the entire history?")
    }

    private func deleteMessage(_ request: DeleteRequest) -> String {
        let keep = String(localized: "Your files — plan, runs, ticks — stay exactly as they are now. Deleted versions are gone for good and cannot be restored.")
        guard let days = request.days else {
            return String(localized: "All \(entries.count) versions will be deleted; the current state becomes the new starting point. ") + keep
        }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let older = entries.filter { $0.date < cutoff }.count
        guard older > 0 else { return String(localized: "There are no versions before \(Fmt.dayMonth(cutoff)) — nothing will happen.") }
        return String(localized: "\(older) versions before \(Fmt.dayMonth(cutoff)) will be deleted; everything after stays available through “Undo”. ") + keep
    }

    private var setUpView: some View {
        ContentUnavailableView {
            Label("Version control is off", systemImage: "clock.badge.questionmark")
        } description: {
            Text("With git, the app records every change to the training folder as a version — from the coach, ticks and loaded runs — and can undo them.")
        } actions: {
            Button {
                settingUp = true
                Task {
                    do { try await model.setUpHistory() } catch { loadError = error.localizedDescription }
                    settingUp = false
                }
            } label: {
                Label("Set up", systemImage: "checkmark.circle")
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
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.locale))
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
                    Text(entry.date.formatted(.dateTime.hour().minute().locale(Fmt.locale)))
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
        switch HistorySubject.kind(of: subject) {
        case .coach: "sparkles"
        case .checkedOff: "checkmark.circle"
        case .unchecked: "circle"
        case .runsLoaded: "figure.run"
        case .assigned: "link"
        case .undone: "arrow.uturn.backward"
        case .plan: "calendar"
        case .initial: "flag"
        case .external: "pencil"
        case .other: "circle.dashed"
        }
    }

    static func color(for subject: String) -> Color {
        switch HistorySubject.kind(of: subject) {
        case .coach: .brand
        case .checkedOff: .green
        case .runsLoaded: .blue
        case .undone: .orange
        case .plan: .purple
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
                    Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Fmt.locale)))
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
                                Label("Undo this change", systemImage: "arrow.uturn.backward")
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
                    SectionTitle(text: String(localized: "Changed files"))
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
                        SectionTitle(text: String(localized: "Changes"))
                        DiffView(lines: diff, truncated: truncated)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .task { await loadDiff() }
        .confirmationDialog("Undo “\(entry.subject)”?", isPresented: $confirmRevert) {
            Button("Undo") { Task { await revert() } }
        } message: {
            Text(isLatest
                 ? "The files go back to the previous version. This is itself recorded as a new version."
                 : "Only these changes are reverted; later ones are kept. This is itself recorded as a new version.")
        }
        .alert("This can’t be done automatically", isPresented: $conflict) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Later changes touch the same places. Undo the later versions first or ask the coach to fix it by hand.")
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
                Text("… truncated")
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
