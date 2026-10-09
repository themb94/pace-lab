import Foundation

/// The plan files next to plan.json.
enum PlanFiles {
    /// Draft for a new block — the coach writes it, the app applies it.
    static let draft = "plan-entwurf.json"
    /// Earlier blocks, stored when a draft is applied.
    static let archive = "plans"

    static func decode(_ data: Data) throws -> TrainingPlan {
        try JSONDecoder.snakeCase.decode(TrainingPlan.self, from: data)
    }
}

/// Readable list of the differences between two plans, e.g. "W3 · Tempo: 4×1000 m … (before: …)".
enum PlanDiff {
    static func changes(from old: TrainingPlan?, to new: TrainingPlan) -> [String] {
        guard let old else { return [String(localized: "New plan: \(new.title)")] }
        if old.idPrefix != new.idPrefix {
            return [String(localized: "New block: \(new.title) · \(new.weeks.count) weeks starting \(day(new.startMonday))")]
        }

        var lines: [String] = []
        if old.title != new.title { lines.append(String(localized: "Title: \(new.title)")) }
        if (old.goal ?? "") != (new.goal ?? "") { lines.append(String(localized: "Goal: \(new.goal ?? "–")")) }
        if old.startMonday != new.startMonday {
            lines.append("Start: \(day(old.startMonday)) → \(day(new.startMonday))")
        }
        if old.weeks.count != new.weeks.count {
            lines.append(String(localized: "Duration: \(old.weeks.count) → \(new.weeks.count) weeks"))
        }

        let oldBands = Dictionary((old.paceBands ?? []).map { ($0.name, $0.range) }, uniquingKeysWith: { a, _ in a })
        let newBands = Dictionary((new.paceBands ?? []).map { ($0.name, $0.range) }, uniquingKeysWith: { a, _ in a })
        for band in new.paceBands ?? [] {
            if let range = oldBands[band.name] {
                if range != band.range { lines.append(String(localized: "Pace band \(band.name): \(range) → \(band.range)")) }
            } else {
                lines.append(String(localized: "New pace band \(band.name): \(band.range)"))
            }
        }
        for band in old.paceBands ?? [] where newBands[band.name] == nil {
            lines.append(String(localized: "Pace band removed: \(band.name)"))
        }
        if old.athlete?.zoneFloors != new.athlete?.zoneFloors || old.athlete?.maxHr != new.athlete?.maxHr {
            lines.append(String(localized: "HR zones adjusted"))
        }

        for index in 0..<max(old.weeks.count, new.weeks.count) {
            let label = "W\(index + 1)"
            guard index < new.weeks.count else {
                lines.append(String(localized: "\(label) dropped"))
                continue
            }
            let week = new.weeks[index]
            guard index < old.weeks.count else {
                lines.append(String(localized: "\(label) new (\(week.phase)): ") + week.sessions.map { "\($0.kind.label) \($0.dist)" }.joined(separator: ", "))
                continue
            }
            let before = old.weeks[index]
            if before.phase != week.phase || (before.note ?? "") != (week.note ?? "") {
                let note = (week.note ?? "").isEmpty ? "" : " · \(week.note!)"
                lines.append("\(label): \(week.phase)\(note)")
            }
            // Match sessions by type (the coach sometimes reorders a week), otherwise by position.
            var unmatched = Array(before.sessions.indices)
            var pairs: [(was: PlanSessionSpec?, now: PlanSessionSpec?)] = []
            for now in week.sessions {
                if let i = unmatched.first(where: { before.sessions[$0].type == now.type }) {
                    unmatched.removeAll { $0 == i }
                    pairs.append((before.sessions[i], now))
                } else {
                    pairs.append((nil, now))
                }
            }
            for i in unmatched {
                if let slot = pairs.firstIndex(where: { $0.was == nil }) {
                    pairs[slot].was = before.sessions[i]
                } else {
                    pairs.append((before.sessions[i], nil))
                }
            }
            let oldOrder = before.sessions.map(\.type), newOrder = week.sessions.map(\.type)
            if oldOrder != newOrder && oldOrder.sorted() == newOrder.sorted() {
                lines.append(String(localized: "\(label): new order – ") + week.sessions.map(\.kind.label).joined(separator: ", "))
            }
            for pair in pairs {
                switch (pair.was, pair.now) {
                case (let was?, nil):
                    lines.append(String(localized: "\(label): \(was.kind.label) \(was.dist) dropped"))
                case (nil, let now?):
                    lines.append(String(localized: "\(label) new: \(now.kind.label) \(now.dist) – \(now.desc)"))
                case (let was?, let now?):
                    if was.type != now.type || was.dist != now.dist || was.desc != now.desc {
                        lines.append(String(localized: "\(label) · \(now.kind.label): \(now.dist) – \(now.desc) (before: \(was.kind.label) \(was.dist) – \(was.desc))"))
                    } else if was.workout != now.workout {
                        lines.append(String(localized: "\(label) · \(now.kind.label): workout steps adjusted"))
                    }
                default:
                    break
                }
            }
        }
        return lines
    }

    private static func day(_ iso: String) -> String {
        DateUtil.day(fromISO: iso).map(Fmt.dayMonth) ?? iso
    }
}

/// Readable description of a workout step, e.g. "800 m @ 4:45–5:15".
enum WorkoutText {
    static func describe(_ step: WorkoutStep, bands: [PaceBand]) -> String {
        var amount = ""
        if let distance = step.distance {
            amount = distance >= 1000 ? "\(Fmt.km(distance / 1000, digits: distance.truncatingRemainder(dividingBy: 1000) == 0 ? 0 : 1)) km" : "\(Int(distance)) m"
        } else if let time = step.time {
            let seconds = Int(time)
            amount = seconds % 60 == 0 ? "\(seconds / 60) min"
                : seconds < 120 ? "\(seconds) s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60)) min"
        }
        var target = ""
        if let pace = step.pace {
            let range = bands.first { $0.name.caseInsensitiveCompare(pace) == .orderedSame }?.range ?? pace
            target = " @ \(range.replacingOccurrences(of: "-", with: "–"))"
        } else if let hr = step.hr {
            target = String(localized: " @ HR \(hr.replacingOccurrences(of: "-", with: "–"))")
        }
        return amount + target
    }

    static func typeLabel(_ type: String?) -> String {
        switch type {
        case "warmup": String(localized: "Warm-up")
        case "cooldown": String(localized: "Cool-down")
        case "interval": String(localized: "Interval")
        case "recovery": String(localized: "Recovery")
        case "rest": String(localized: "Recovery")
        default: String(localized: "Run")
        }
    }
}
