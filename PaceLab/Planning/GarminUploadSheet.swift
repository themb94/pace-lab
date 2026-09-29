import SwiftUI

/// Legt die Workouts einer Woche direkt über den Garmin-Server an — ohne Coach, aber nur nach Bestätigung.
enum GarminUpload {
    /// Namen der Workouts, die schon im Garmin-Konto liegen.
    static func existingNames(folder: URL) async throws -> Set<String> {
        guard let config = GarminServerConfig.load(from: folder) else { throw SyncFailure(message: "Kein Garmin-Server eingerichtet (.mcp.json fehlt).") }
        let client = try await config.connect(in: folder, readOnly: true)
        defer { client.close() }
        let text = try await client.callTool("list_workouts", timeout: 60)
        if text.hasPrefix("❌") { throw SyncFailure(message: "Garmin meldet: \(text.dropFirst().trimmingCharacters(in: .whitespaces))") }
        // "12 Workouts:\n<id>  <name>\n…"
        return Set(text.split(separator: "\n").dropFirst().compactMap { line in
            line.range(of: "  ").map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
        })
    }

    /// Legt alle Nicht-Locker-Workouts der Woche an; gleichnamige werden vorher gelöscht.
    static func upload(week: Int, folder: URL) async throws -> [String] {
        guard let config = GarminServerConfig.load(from: folder) else { throw SyncFailure(message: "Kein Garmin-Server eingerichtet (.mcp.json fehlt).") }
        let client = try await config.connect(in: folder, readOnly: false)
        defer { client.close() }
        let text = try await client.callTool("create_plan", arguments: ["week": week, "replace_existing": true], timeout: 240)
        if text.hasPrefix("❌") { throw SyncFailure(message: "Garmin meldet: \(text.dropFirst().trimmingCharacters(in: .whitespaces))") }
        return text.split(separator: "\n").map(String.init)
    }
}

struct GarminUploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let week: Int

    private enum Phase {
        case checking
        case ready(existing: Set<String>)
        case uploading
        case done([String])
        case failed(String)
    }

    @State private var phase = Phase.checking

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Woche \(week) auf Garmin anlegen", systemImage: "applewatch")
                .font(.title2.bold())
            if let snapshot = model.snapshot {
                content(snapshot)
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await check() }
    }

    @ViewBuilder
    private func content(_ snapshot: TrainingSnapshot) -> some View {
        let sessions = snapshot.sessions(inWeek: week)
        let existing: Set<String> = if case .ready(let names) = phase { names } else { [] }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sessions) { session in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TypePill(kind: session.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.garminName ?? "\(session.kind.label) \(session.dist)")
                            .font(.headline)
                        Text(session.desc).font(.callout).foregroundStyle(.secondary)
                        if !session.isUploadable {
                            Text(session.kind == .easy ? "Lockere Läufe kommen nicht auf die Uhr (Plan-Option uploadEasyRuns)." : "Kein Workout in plan.json.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let name = session.garminName, existing.contains(name) {
                            Label("Schon auf Garmin — wird ersetzt", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .opacity(session.isUploadable ? 1 : 0.55)
            }
        }
        .card(padding: 14)

        switch phase {
        case .checking:
            Label("Prüfe, was schon auf Garmin liegt …", systemImage: "magnifyingglass").foregroundStyle(.secondary)
        case .ready:
            Text("Die Workouts erscheinen danach auf der Uhr unter Training › Workouts. Sie werden nicht automatisch in den Kalender gelegt.")
                .font(.callout).foregroundStyle(.secondary)
        case .uploading:
            HStack { ProgressView().controlSize(.small); Text("Lege Workouts an …") }
        case .done(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0).font(.callout) }
            }
            .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .done:
            Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
        case .checking:
            Button("Abbrechen", role: .cancel) { dismiss() }
        case .uploading:
            EmptyView()
        case .ready, .failed:
            Button("Abbrechen", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await upload() }
            } label: {
                Label("Auf Garmin anlegen", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.brand)
            .keyboardShortcut(.defaultAction)
            .disabled(!(model.snapshot?.sessions(inWeek: week).contains(where: \.isUploadable) ?? false))
        }
    }

    private func check() async {
        do {
            phase = .ready(existing: try await GarminUpload.existingNames(folder: model.folder.url))
        } catch {
            // Ohne Liste geht es trotzdem — gleichnamige Workouts werden beim Anlegen ohnehin ersetzt.
            phase = .ready(existing: [])
        }
    }

    private func upload() async {
        phase = .uploading
        do {
            phase = .done(try await GarminUpload.upload(week: week, folder: model.folder.url))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
