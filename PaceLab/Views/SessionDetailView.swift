import SwiftUI

/// Details einer Plan-Einheit (rechter Inspector im Plan).
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
                        "Woche \(session.week) · \(Fmt.range(snapshot.monday(ofWeek: session.week), snapshot.sunday(ofWeek: session.week)))"
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
                            Label(session.isUploadable
                                  ? "Auf der Uhr als „\(session.garminName ?? workout.name)“"
                                  : "Lockere Läufe kommen nicht auf die Uhr — nach Gefühl laufen.",
                                  systemImage: "applewatch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card(padding: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(isDone ? (snapshot.doneDate(session).map { "Erledigt am \($0)" } ?? "Erledigt") : "Noch offen")
                    } icon: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(isDone ? .green : .secondary)
                    }
                    .font(.headline)

                    Button {
                        withAnimation { model.toggleDone(session) }
                    } label: {
                        Label(isDone ? "Als offen markieren" : "Als erledigt markieren",
                              systemImage: isDone ? "arrow.uturn.backward" : "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isDone ? .gray : .green)
                    .controlSize(.large)

                    Text("Schreibt direkt in completed.json — der Coach sieht es auch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .card()

                VStack(spacing: 8) {
                    Button {
                        model.requestPlan(.session, session: session)
                    } label: {
                        Label("Mit Coach ändern …", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.coach.isRunning)
                    if session.isUploadable {
                        Button {
                            model.garminUploadWeek = session.week
                        } label: {
                            Label("Woche \(session.week) auf Garmin anlegen …", systemImage: "applewatch")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .controlSize(.large)

                if let run = snapshot.linkedRun(for: session) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Gelaufen")
                        Button { model.show(run) } label: {
                            RunRow(run: run, label: snapshot.label(for: run)).card(padding: 12)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }

                if session.kind == .tempo, let bands = snapshot.plan.paceBands, !bands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Pace-Bänder")
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(bands, id: \.self) { band in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(band.name)
                                    Spacer()
                                    Text("\(band.range) /km").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            Text("Auf-/Auslaufen und Trabpausen ohne Ziel. An warmen Tagen (>25 °C) lieber die HF deckeln als die Pace jagen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card(padding: 14)
                    }
                }

                if let summary = snapshot.summary(forWeek: session.week), let analysis = summary.analysis {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Wochenfazit")
                        Text(analysis).font(.callout).card(padding: 14)
                    }
                }
            }
            .padding(16)
        }
    }
}
