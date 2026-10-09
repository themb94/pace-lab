import Foundation

// The models mirror the JSON files in the project root 1:1 (plan.json,
// analysis.json, completed.json). Fields are
// generously optional so that a new/missing field never breaks loading.

// MARK: - plan.json

struct TrainingPlan: Codable, Sendable {
    var title: String
    var goal: String?
    var subtitle: String?
    var previous: String?
    /// Monday of the first block week, `yyyy-MM-dd`.
    var startMonday: String
    /// Prefix of the session IDs, e.g. "b1" → `b1w1-tempo-0`.
    var idPrefix: String?
    /// Prefix of the Garmin workout names, e.g. "PL" → "PL W01 · 6x800m".
    var workoutPrefix: String?
    /// Also create easy runs as a Garmin workout (default: no, they're run by feel).
    var uploadEasyRuns: Bool?
    var athlete: Athlete?
    var paceBands: [PaceBand]?
    var weeks: [PlanWeek]
}

struct Athlete: Codable, Sendable {
    var maxHr: Int
    /// Lower bounds of HR zones 2–5 in bpm.
    var zoneFloors: [Int]
}

struct PaceBand: Codable, Sendable, Hashable {
    var name: String
    var range: String
    var note: String?
}

struct PlanWeek: Codable, Sendable {
    var phase: String
    var note: String?
    var sessions: [PlanSessionSpec]
}

struct PlanSessionSpec: Codable, Sendable {
    /// Raw type as in the JSON — goes into the session ID unchanged.
    var type: String
    var dist: String
    var desc: String
    /// Steps for the watch — garmin_workouts.py builds the Garmin workout from these.
    var workout: PlanWorkout?

    var kind: SessionType { SessionType(rawValue: type) ?? .easy }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        dist = try c.decodeIfPresent(String.self, forKey: .dist) ?? ""
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        // A faulty workout must never make the whole plan unreadable.
        workout = try? c.decodeIfPresent(PlanWorkout.self, forKey: .workout)
    }
}

/// Workout of a session (schema in the README, section "Plan schema").
struct PlanWorkout: Codable, Sendable, Hashable {
    var name: String
    var steps: [WorkoutStep]
}

/// A section of a workout — or a repetition (`repeat` + `steps`).
struct WorkoutStep: Codable, Sendable, Hashable {
    /// warmup | cooldown | interval | recovery | run
    var type: String?
    /// Meters
    var distance: Double?
    /// Seconds
    var time: Double?
    /// Name of a pace band or "m:ss-m:ss"
    var pace: String?
    /// HR range "lo-hi"
    var hr: String?
    var note: String?
    var `repeat`: Int?
    var steps: [WorkoutStep]?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return value }
            return (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { Double($0) }
        }
        func text(_ key: CodingKeys) -> String? {
            if let value = try? c.decodeIfPresent(String.self, forKey: key) { return value }
            return number(key).map { String(Int($0)) }
        }
        type = text(.type)
        distance = number(.distance)
        time = number(.time)
        pace = text(.pace)
        hr = text(.hr)
        note = text(.note)
        `repeat` = number(.repeat).map { Int($0) }
        steps = try? c.decodeIfPresent([WorkoutStep].self, forKey: .steps)
    }
}

enum SessionType: String, Sendable, CaseIterable {
    case tempo, easy, long, race
}

// MARK: - analysis.json

struct AnalysisFile: Codable, Sendable {
    var runs: [Run]
    var weekSummaries: [WeekSummary]?
}

struct Run: Codable, Sendable, Identifiable, Hashable {
    var stravaId: String?
    var garminId: String?
    var polarId: String?
    var source: String?
    /// Plan session (`b1w1-tempo-0`, older IDs without prefix `w3-long-2`) or nil for extra runs.
    var sessionId: String?
    var tag: String?
    var name: String
    /// `yyyy-MM-dd`
    var date: String
    var distanceKm: Double?
    var movingTimeS: Double?
    var avgPaceS: Double?
    var avgHr: Double?
    var maxHr: Double?
    var relativeEffort: Double?
    var elevationGain: Double?
    var cadence: Double?
    var weather: String?
    var flags: [String]?
    var splits: [Split]?
    var verdict: Verdict?
    var analysis: String?
    var adjustments: String?

    var id: String { stravaId ?? garminId ?? polarId ?? "\(date)-\(name)" }

    /// Not yet rated or analyzed — e.g. just loaded from Strava, Garmin or Polar.
    var isAnalyzed: Bool { verdict != nil || !(analysis ?? "").isEmpty }

    static func == (lhs: Run, rhs: Run) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var day: Date? { DateUtil.day(fromISO: date) }

    /// Avg pace in s/km; falls back to time/distance if the field is missing.
    var paceSeconds: Double? {
        if let avgPaceS, avgPaceS > 0 { return avgPaceS }
        guard let movingTimeS, let distanceKm, distanceKm > 0 else { return nil }
        return movingTimeS / distanceKm
    }

    var stravaURL: URL? {
        stravaId.flatMap { URL(string: "https://www.strava.com/activities/\($0)") }
    }

    var garminURL: URL? {
        garminId.flatMap { URL(string: "https://connect.garmin.com/modern/activity/\($0)") }
    }
}

struct Split: Codable, Sendable, Hashable {
    var km: Int?
    var label: String?
    var paceS: Double
    var hr: Double?

    var title: String { label ?? "km \(km ?? 0)" }
}

enum Verdict: String, Codable, Sendable {
    case gut, ok, achtung

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // The English template writes "good" / "warning", the German one "gut" / "achtung".
        switch raw.lowercased() {
        case "good": self = .gut
        case "warning", "warn": self = .achtung
        default: self = Verdict(rawValue: raw.lowercased()) ?? .ok
        }
    }
}

struct WeekSummary: Codable, Sendable {
    var week: Int
    var analysis: String?
    var nextWeekChanges: String?
}

// MARK: - completed.json

/// `{ "b1w1-tempo-0": "05.01.2026", … }` — `true` is also allowed as a value.
struct CompletionFile: Decodable, Sendable {
    /// Session ID → date (empty if checked off without a date).
    var marks: [String: String]

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Mark].self)
        marks = raw.compactMapValues(\.date)
    }

    private struct Mark: Decodable {
        let date: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                date = s
            } else if let b = try? c.decode(Bool.self), b {
                date = ""
            } else {
                date = nil
            }
        }
    }
}

extension JSONDecoder {
    /// For plan.json / analysis.json (`distance_km` → `distanceKm`).
    static var snakeCase: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
