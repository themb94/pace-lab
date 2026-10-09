import Foundation

/// A planned session with its session ID (`b1w1-tempo-0`), as used by completed.json.
struct PlannedSession: Identifiable, Hashable, Sendable {
    let id: String
    let week: Int
    let index: Int
    let kind: SessionType
    let dist: String
    let desc: String
    let phase: String
    let weekNote: String?
    let workout: PlanWorkout?
    /// Name of the Garmin workout, e.g. "PL W01 · 6x800m" (nil without a workout).
    let garminName: String?

    /// Goes to the watch as a workout: with a workout; easy runs only with `uploadEasyRuns` in the plan.
    let isUploadable: Bool

    /// Planned km: mean of all numbers in the distance text ("~9 km" → 9).
    var plannedKm: Double { Self.parseKm(dist) }

    static func parseKm(_ text: String) -> Double {
        let numbers = text.replacingOccurrences(of: ",", with: ".")
            .split(whereSeparator: { !"0123456789.".contains($0) })
            .compactMap { Double($0) }
        guard !numbers.isEmpty else { return 0 }
        return numbers.reduce(0, +) / Double(numbers.count)
    }
}

enum BlockStatus: Sendable, Equatable {
    case upcoming(daysUntilStart: Int)
    case running(week: Int)
    case finished
}

struct WeekBucket: Identifiable, Sendable {
    let monday: Date
    /// Block week (1…n), or nil if the calendar week lies outside the block.
    let blockWeek: Int?
    let actualKm: Double
    let plannedKm: Double?

    var id: Date { monday }
}

/// Everything the app and widgets display — loaded once, derived from then on.
struct TrainingSnapshot: Sendable {
    let plan: TrainingPlan
    /// Newest first.
    let runs: [Run]
    let weekSummaries: [WeekSummary]
    /// Session ID → date ("" = checked off without a date).
    let completed: [String: String]
    let sessions: [PlannedSession]
    let startMonday: Date

    init(plan: TrainingPlan, analysis: AnalysisFile, completed: [String: String]) {
        self.plan = plan
        self.completed = completed
        self.weekSummaries = analysis.weekSummaries ?? []
        // ISO dates sort correctly lexicographically.
        self.runs = analysis.runs.sorted { $0.date > $1.date }
        self.startMonday = DateUtil.day(fromISO: plan.startMonday) ?? DateUtil.startOfWeek(.now)

        let prefix = plan.idPrefix ?? "b2"
        // Like garmin_workouts.py: workoutPrefix, otherwise the ID prefix in uppercase.
        let workoutPrefix = plan.workoutPrefix ?? (plan.idPrefix ?? "").uppercased()
        self.sessions = plan.weeks.enumerated().flatMap { wi, week in
            week.sessions.enumerated().map { si, s in
                PlannedSession(
                    id: "\(prefix)w\(wi + 1)-\(s.type)-\(si)",
                    week: wi + 1,
                    index: si,
                    kind: s.kind,
                    dist: s.dist,
                    desc: s.desc,
                    phase: week.phase,
                    weekNote: (week.note?.isEmpty ?? true) ? nil : week.note,
                    workout: s.workout,
                    garminName: s.workout.map {
                        "\(workoutPrefix) W\(String(format: "%02d", wi + 1)) · \($0.name)"
                            .trimmingCharacters(in: .whitespaces)
                    },
                    isUploadable: s.workout != nil && (s.kind != .easy || plan.uploadEasyRuns == true)
                )
            }
        }
    }
}

// MARK: - Block weeks

extension TrainingSnapshot {
    var weekCount: Int { plan.weeks.count }

    func monday(ofWeek week: Int) -> Date {
        DateUtil.calendar.date(byAdding: .day, value: (week - 1) * 7, to: startMonday)!
    }

    func sunday(ofWeek week: Int) -> Date {
        DateUtil.calendar.date(byAdding: .day, value: 6, to: monday(ofWeek: week))!
    }

    func status(on date: Date) -> BlockStatus {
        let diff = DateUtil.days(from: startMonday, to: date)
        if diff < 0 { return .upcoming(daysUntilStart: -diff) }
        let week = diff / 7 + 1
        return week > weekCount ? .finished : .running(week: week)
    }

    /// The week that currently counts: the current block week, before the block week 1, after it the last one.
    func focusWeek(on date: Date) -> Int {
        switch status(on: date) {
        case .upcoming: 1
        case .running(let week): week
        case .finished: weekCount
        }
    }

    func blockWeek(containing date: Date) -> Int? {
        let diff = DateUtil.days(from: startMonday, to: date)
        guard diff >= 0 else { return nil }
        let week = diff / 7 + 1
        return week <= weekCount ? week : nil
    }

    func phase(ofWeek week: Int) -> String { plan.weeks[week - 1].phase }

    func note(ofWeek week: Int) -> String? {
        let note = plan.weeks[week - 1].note
        return (note?.isEmpty ?? true) ? nil : note
    }

    func summary(forWeek week: Int) -> WeekSummary? {
        weekSummaries.first { $0.week == week }
    }

    /// "Week 3 · Build" or "Starts in 4 days"
    func statusLine(on date: Date) -> String {
        switch status(on: date) {
        case .upcoming(let days): String(localized: "Starts \(Fmt.relativeDays(days))")
        case .running(let week): String(localized: "Week \(week) · \(phase(ofWeek: week))")
        case .finished: String(localized: "Block completed")
        }
    }
}

// MARK: - Sessions & completion status

extension TrainingSnapshot {
    func sessions(inWeek week: Int) -> [PlannedSession] {
        sessions.filter { $0.week == week }
    }

    func session(id: String) -> PlannedSession? {
        sessions.first { $0.id == id }
    }

    func isDone(_ session: PlannedSession) -> Bool { completed[session.id] != nil }

    func doneDate(_ session: PlannedSession) -> String? {
        guard let date = completed[session.id], !date.isEmpty else { return nil }
        return date
    }

    var nextSession: PlannedSession? { sessions.first { !isDone($0) } }

    var doneCount: Int { sessions.filter(isDone).count }

    func linkedRun(for session: PlannedSession) -> Run? {
        runs.first { $0.sessionId == session.id }
    }
}

// MARK: - Runs & kilometers

extension TrainingSnapshot {
    var lastRun: Run? { runs.first }

    var totalKm: Double { runs.reduce(0) { $0 + ($1.distanceKm ?? 0) } }

    func run(id: String) -> Run? { runs.first { $0.id == id } }

    /// Runs between two days (both inclusive).
    func runs(from start: Date, through end: Date) -> [Run] {
        let lower = DateUtil.calendar.startOfDay(for: start)
        let upper = DateUtil.calendar.startOfDay(for: end)
        return runs.filter { run in
            guard let day = run.day else { return false }
            return day >= lower && day <= upper
        }
    }

    func actualKm(week: Int) -> Double {
        runs(from: monday(ofWeek: week), through: sunday(ofWeek: week))
            .reduce(0) { $0 + ($1.distanceKm ?? 0) }
    }

    func plannedKm(week: Int) -> Double {
        sessions(inWeek: week).reduce(0) { $0 + $1.plannedKm }
    }

    /// Calendar weeks from `firstMonday`, each with run vs. planned (if a block week).
    func weeklyBuckets(from firstMonday: Date, count: Int) -> [WeekBucket] {
        let cal = DateUtil.calendar
        let start = DateUtil.startOfWeek(firstMonday)
        return (0..<count).map { offset in
            let monday = cal.date(byAdding: .day, value: offset * 7, to: start)!
            let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
            let actual = runs(from: monday, through: sunday).reduce(0) { $0 + ($1.distanceKm ?? 0) }
            let week = blockWeek(containing: monday)
            return WeekBucket(monday: monday, blockWeek: week, actualKm: actual, plannedKm: week.map(plannedKm(week:)))
        }
    }

    /// Plan label for a run, e.g. "W3 · TEMPO · ~10 km" — or "B1 W3 · TEMPO" for runs from an
    /// earlier block and "Old W9 · LONG" for IDs without a prefix.
    func label(for run: Run) -> String? {
        guard let id = run.sessionId else { return nil }
        if let s = session(id: id) {
            return "W\(s.week) · \(s.kind.shortLabel) · \(s.dist)"
        }
        // {prefix}w{week}-{type}-{index}; very old plans had no prefix.
        guard let match = id.wholeMatch(of: /([a-z]*\d*?)w(\d+)-([a-z]+)-\d+/), let week = Int(match.2) else { return nil }
        let kind = SessionType(rawValue: String(match.3)) ?? .easy
        let prefix = String(match.1)
        let block = prefix.isEmpty ? String(localized: "Old") + " " : prefix == plan.idPrefix ? "" : "\(prefix.uppercased()) "
        return "\(block)W\(week) · \(kind.shortLabel)"
    }
}

// MARK: - Heart rate zones

extension TrainingSnapshot {
    var zoneFloors: [Int] { plan.athlete?.zoneFloors ?? [122, 142, 162, 183] }

    func zone(forHR hr: Double) -> Int {
        var zone = 1
        for (i, floor) in zoneFloors.enumerated() where hr >= Double(floor) {
            zone = i + 2
        }
        return zone
    }

    /// Z1 <122 · Z2 122–142 · … · Z5 183+
    var zoneLegend: [(zone: Int, range: String)] {
        let f = zoneFloors
        return (1...f.count + 1).map { z in
            switch z {
            case 1: (z, "<\(f[0])")
            case f.count + 1: (z, "\(f[f.count - 1])+")
            default: (z, "\(f[z - 2])–\(f[z - 1])")
            }
        }
    }
}
