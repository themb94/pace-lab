import SwiftUI

/// Kleines Panel in der Menüleiste: nächste Einheit, Wochenstand, Coach.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                let week = snapshot.focusWeek(on: .now)
                let sessions = snapshot.sessions(inWeek: week)
                let planned = snapshot.plannedKm(week: week)
                let actual = snapshot.actualKm(week: week)

                Text(snapshot.statusLine(on: .now))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .textCase(.uppercase)

                if let next = snapshot.nextSession {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TypePill(kind: next.kind)
                            Text(next.dist).font(.title3.bold())
                        }
                        Text(next.desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Week \(week): \(sessions.filter(snapshot.isDone).count)/\(sessions.count) sessions · \(Fmt.km(actual)) of \(Fmt.km(planned, digits: 0)) km")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressBar(value: planned > 0 ? actual / planned : 0)
                }
            } else {
                Text(model.loadError ?? String(localized: "No training data")).foregroundStyle(.secondary)
            }

            if model.coach.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.coach.liveStep ?? String(localized: "Coach is working …"))
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            if let step = model.sync.step {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout).lineLimit(1)
                }
            } else if case .finished(let summary) = model.sync.state {
                Label(summary.message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = model.sync.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            Divider()

            Button {
                model.syncRuns()
            } label: {
                Label("Load runs (\(SyncSettings.source.shortLabel))", systemImage: "arrow.down.circle")
            }
            .disabled(model.sync.isRunning || model.coach.isRunning || model.snapshot == nil)

            Button {
                open(.overview)
            } label: {
                Label("Open Pace Lab", systemImage: "macwindow")
            }
            Button {
                model.startCoach(.reviewWeek)
                open(.coach)
            } label: {
                Label("Review week", systemImage: "sparkles")
            }
            .disabled(model.coach.isRunning || model.sync.isRunning || !model.coach.activeEngine.kind.isAgent)

            Divider()

            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Label("Settings …", systemImage: "gearshape")
            }
            Button("Quit Pace Lab") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 310)
    }

    private func open(_ section: SidebarItem) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
