import Foundation

/// Die Plan-Dateien neben plan.json.
enum PlanFiles {
    /// Entwurf für einen neuen Block — der Coach schreibt ihn, übernommen wird er in der App.
    static let draft = "plan-entwurf.json"
    /// Frühere Blöcke, beim Übernehmen eines Entwurfs abgelegt.
    static let archive = "plans"

    static func decode(_ data: Data) throws -> TrainingPlan {
        try JSONDecoder.snakeCase.decode(TrainingPlan.self, from: data)
    }
}

/// Lesbare Liste der Unterschiede zwischen zwei Plänen, z. B. „W3 · Tempo: 4×1000 m … (vorher: …)“.
enum PlanDiff {
    static func changes(from old: TrainingPlan?, to new: TrainingPlan) -> [String] {
        guard let old else { return ["Neuer Plan: \(new.title)"] }
        if old.idPrefix != new.idPrefix {
            return ["Neuer Block: \(new.title) · \(new.weeks.count) Wochen ab \(day(new.startMonday))"]
        }

        var lines: [String] = []
        if old.title != new.title { lines.append("Titel: \(new.title)") }
        if (old.goal ?? "") != (new.goal ?? "") { lines.append("Ziel: \(new.goal ?? "–")") }
        if old.startMonday != new.startMonday {
            lines.append("Start: \(day(old.startMonday)) → \(day(new.startMonday))")
        }
        if old.weeks.count != new.weeks.count {
            lines.append("Dauer: \(old.weeks.count) → \(new.weeks.count) Wochen")
        }

        let oldBands = Dictionary((old.paceBands ?? []).map { ($0.name, $0.range) }, uniquingKeysWith: { a, _ in a })
        let newBands = Dictionary((new.paceBands ?? []).map { ($0.name, $0.range) }, uniquingKeysWith: { a, _ in a })
        for band in new.paceBands ?? [] {
            if let range = oldBands[band.name] {
                if range != band.range { lines.append("Pace-Band \(band.name): \(range) → \(band.range)") }
            } else {
                lines.append("Neues Pace-Band \(band.name): \(band.range)")
            }
        }
        for band in old.paceBands ?? [] where newBands[band.name] == nil {
            lines.append("Pace-Band entfernt: \(band.name)")
        }
        if old.athlete?.zoneFloors != new.athlete?.zoneFloors || old.athlete?.maxHr != new.athlete?.maxHr {
            lines.append("HF-Zonen angepasst")
        }

        for index in 0..<max(old.weeks.count, new.weeks.count) {
            let label = "W\(index + 1)"
            guard index < new.weeks.count else {
                lines.append("\(label) entfällt")
                continue
            }
            let week = new.weeks[index]
            guard index < old.weeks.count else {
                lines.append("\(label) neu (\(week.phase)): " + week.sessions.map { "\($0.kind.label) \($0.dist)" }.joined(separator: ", "))
                continue
            }
            let before = old.weeks[index]
            if before.phase != week.phase || (before.note ?? "") != (week.note ?? "") {
                let note = (week.note ?? "").isEmpty ? "" : " · \(week.note!)"
                lines.append("\(label): \(week.phase)\(note)")
            }
            // Einheiten nach Typ zuordnen (der Coach sortiert eine Woche auch mal um), sonst nach Position.
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
                lines.append("\(label): neue Reihenfolge – " + week.sessions.map(\.kind.label).joined(separator: ", "))
            }
            for pair in pairs {
                switch (pair.was, pair.now) {
                case (let was?, nil):
                    lines.append("\(label): \(was.kind.label) \(was.dist) entfällt")
                case (nil, let now?):
                    lines.append("\(label) neu: \(now.kind.label) \(now.dist) – \(now.desc)")
                case (let was?, let now?):
                    if was.type != now.type || was.dist != now.dist || was.desc != now.desc {
                        lines.append("\(label) · \(now.kind.label): \(now.dist) – \(now.desc) (vorher: \(was.kind.label) \(was.dist) – \(was.desc))")
                    } else if was.workout != now.workout {
                        lines.append("\(label) · \(now.kind.label): Workout-Schritte angepasst")
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

/// Lesbare Beschreibung eines Workout-Schritts, z. B. „800 m @ 4:45–5:15“.
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
            target = " @ HF \(hr.replacingOccurrences(of: "-", with: "–"))"
        }
        return amount + target
    }

    static func typeLabel(_ type: String?) -> String {
        switch type {
        case "warmup": "Einlaufen"
        case "cooldown": "Auslaufen"
        case "interval": "Belastung"
        case "recovery": "Pause"
        case "rest": "Pause"
        default: "Lauf"
        }
    }
}
