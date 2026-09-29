import SwiftUI

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var didScroll = false

    var body: some View {
        @Bindable var model = model
        let draftMode = model.showDraft && model.draft != nil
        Group {
            if draftMode, let draft = model.draft {
                DraftPlanView(draft: draft)
            } else if let snapshot = model.snapshot {
                list(snapshot)
            } else {
                LoadErrorView()
            }
        }
        .navigationTitle(draftMode ? "Entwurf" : "Plan")
        .inspector(isPresented: Binding(get: { model.showSessionInspector && !draftMode },
                                        set: { model.showSessionInspector = $0 })) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
        .toolbar {
            if model.draft != nil {
                ToolbarItem {
                    Picker("Ansicht", selection: $model.showDraft) {
                        Text("Aktueller Block").tag(false)
                        Text("Entwurf").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Zwischen aktuellem Plan und dem Entwurf für den nächsten Block wechseln")
                }
            }
            ToolbarItem {
                Menu {
                    Button("Woche anpassen …") { model.requestPlan(.week) }
                    Button("Einheit ändern …") {
                        model.requestPlan(.session, session: model.selectedSessionID.flatMap { model.snapshot?.session(id: $0) })
                    }
                    Divider()
                    Button("Neuen Block planen …") { model.requestPlan(.block) }
                } label: {
                    Label("Planen", systemImage: "wand.and.stars")
                }
                .help("Mit dem Coach planen (⇧⌘P)")
                .disabled(model.coach.isRunning || model.snapshot == nil)
            }
            ToolbarItem {
                Button {
                    model.showSessionInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Details zur ausgewählten Einheit ein-/ausblenden")
                .disabled(draftMode)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let snapshot = model.snapshot, let id = model.selectedSessionID, let session = snapshot.session(id: id) {
            SessionDetailView(session: session, snapshot: snapshot)
        } else {
            ContentUnavailableView("Einheit auswählen", systemImage: "calendar",
                                   description: Text("Klick auf eine Einheit, um Details zu sehen."))
        }
    }

    private func list(_ snapshot: TrainingSnapshot) -> some View {
        @Bindable var model = model
        let focus = snapshot.focusWeek(on: .now)
        return ScrollViewReader { proxy in
            List(selection: $model.selectedSessionID) {
                if let draft = model.draft {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "pencil.and.list.clipboard").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Entwurf für den nächsten Block: \(draft.title)").font(.headline)
                                Text("\(draft.weeks.count) Wochen ab \(DateUtil.day(fromISO: draft.startMonday).map(Fmt.longDate) ?? draft.startMonday)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ansehen") { model.showDraft = true }
                        }
                        .padding(.vertical, 4)
                        .selectionDisabled()
                    }
                } else if let error = model.draftError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .selectionDisabled()
                    }
                }

                Section("Geplant vs. gelaufen") {
                    WeeklyKmChart(
                        buckets: snapshot.weeklyBuckets(from: snapshot.startMonday, count: snapshot.weekCount),
                        currentMonday: DateUtil.startOfWeek(.now))
                        .padding(.vertical, 8)
                        .selectionDisabled()
                }

                ForEach(1...snapshot.weekCount, id: \.self) { week in
                    Section {
                        ForEach(snapshot.sessions(inWeek: week)) { session in
                            PlanSessionRow(session: session, snapshot: snapshot)
                                .tag(session.id)
                                .id(session.id)
                        }
                        if let summary = snapshot.summary(forWeek: week) {
                            WeekSummaryRow(week: week, summary: summary)
                                .selectionDisabled()
                        }
                    } header: {
                        WeekHeader(snapshot: snapshot, week: week, isCurrent: week == focus)
                            .id("week-\(week)")
                    }
                }

                if let bands = snapshot.plan.paceBands, !bands.isEmpty {
                    Section("Pace-Bänder") {
                        ForEach(bands, id: \.self) { band in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading) {
                                    Text(band.name)
                                    if let note = band.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(band.range) /km").monospacedDigit()
                            }
                            .selectionDisabled()
                        }
                        Text("Locker-Läufe nach Gefühl, Long Runs nur Distanz. Pace-Vorgaben gelten nur für die harten Abschnitte.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }

                Section("HF-Zonen" + (snapshot.plan.athlete.map { " (HFmax \($0.maxHr))" } ?? "")) {
                    ZoneLegend(snapshot: snapshot)
                        .padding(.vertical, 4)
                        .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .onAppear {
                guard !didScroll else { return }
                didScroll = true
                if let id = model.selectedSessionID {
                    proxy.scrollTo(id, anchor: .center)
                } else if focus > 1 {
                    proxy.scrollTo("week-\(focus)", anchor: .top)
                }
            }
            .onChange(of: model.selectedSessionID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct WeekHeader: View {
    let snapshot: TrainingSnapshot
    let week: Int
    let isCurrent: Bool

    var body: some View {
        let sessions = snapshot.sessions(inWeek: week)
        let done = sessions.filter(snapshot.isDone).count
        HStack(spacing: 8) {
            Text("Woche \(week)")
                .font(.headline)
                .foregroundStyle(.primary)
            if isCurrent { Pill(text: "AKTUELL", color: .brand) }
            PhasePill(phase: snapshot.phase(ofWeek: week))
            Text(Fmt.range(snapshot.monday(ofWeek: week), snapshot.sunday(ofWeek: week))
                 + (snapshot.note(ofWeek: week).map { " · \($0)" } ?? ""))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(Fmt.km(snapshot.plannedKm(week: week), digits: 0)) km")
                .foregroundStyle(.secondary)
            Text("\(done)/\(sessions.count)")
                .monospacedDigit()
                .foregroundStyle(done == sessions.count ? .green : .secondary)
            WeekMenu(week: week, uploadable: sessions.contains(where: \.isUploadable))
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// „…“-Menü einer Woche: mit dem Coach anpassen oder direkt auf Garmin anlegen.
private struct WeekMenu: View {
    @Environment(AppModel.self) private var model
    let week: Int
    let uploadable: Bool

    var body: some View {
        Menu {
            Button {
                model.requestPlan(.week, week: week)
            } label: {
                Label("Mit Coach anpassen …", systemImage: "wand.and.stars")
            }
            .disabled(model.coach.isRunning)
            Button {
                model.garminUploadWeek = week
            } label: {
                Label("Auf Garmin anlegen …", systemImage: "applewatch")
            }
            .disabled(!uploadable)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Woche \(week): anpassen oder auf Garmin anlegen")
    }
}

private struct PlanSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: PlannedSession
    let snapshot: TrainingSnapshot

    var body: some View {
        let isDone = snapshot.isDone(session)
        HStack(alignment: .top, spacing: 12) {
            DoneToggle(isDone: isDone) {
                withAnimation { model.toggleDone(session) }
            }
            SessionRowContent(
                session: session,
                isDone: isDone,
                doneDate: snapshot.doneDate(session),
                hasRun: snapshot.linkedRun(for: session) != nil)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(isDone ? "Als offen markieren" : "Als erledigt markieren") { model.toggleDone(session) }
            if let run = snapshot.linkedRun(for: session) {
                Button("Analyse öffnen") { model.show(run) }
            }
            Divider()
            Button("Mit Coach ändern …") { model.requestPlan(.session, session: session) }
                .disabled(model.coach.isRunning)
            Button("Woche mit Coach anpassen …") { model.requestPlan(.week, week: session.week) }
                .disabled(model.coach.isRunning)
        }
    }
}

private struct WeekSummaryRow: View {
    let week: Int
    let summary: WeekSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let analysis = summary.analysis {
                Text("Wochenfazit").font(.caption.weight(.bold)).foregroundStyle(Color.brand)
                Text(analysis).font(.callout)
            }
            if let changes = summary.nextWeekChanges {
                Text("Anpassungen Woche \(week + 1)").font(.caption.weight(.bold)).foregroundStyle(.orange)
                Text(changes).font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}
