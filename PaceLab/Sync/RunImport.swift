import Foundation

/// Where the app gets new runs from (Settings → Runs): the profile's watch or Strava.
enum RunSource: String, CaseIterable, Identifiable, Sendable {
    case garmin, polar, strava

    var id: String { rawValue }

    var label: String {
        switch self {
        case .garmin: String(localized: "Garmin Connect (direct)")
        case .polar: String(localized: "Polar Flow (direct)")
        case .strava: String(localized: "Strava (via Claude Code)")
        }
    }

    var shortLabel: String {
        switch self {
        case .garmin: "Garmin"
        case .polar: "Polar"
        case .strava: "Strava"
        }
    }

    /// Key of the activity ID in analysis.json.
    var idKey: String { "\(rawValue)Id" }
}

/// A newly loaded run, ready as an entry for analysis.json — not yet rated or analyzed.
struct ImportedRun: Sendable {
    private(set) var entry: OrderedJSON
    let source: RunSource
    /// Activity ID at the source.
    let activityID: String
    /// `yyyy-MM-dd`
    let date: String
    let name: String
    let distanceKm: Double
    private(set) var sessionID: String?

    mutating func assign(_ session: String?) {
        sessionID = session
        entry["sessionId"] = session.map(OrderedJSON.string) ?? .null
    }

    /// "29.09. 6x800m" for history and messages.
    var shortDescription: String {
        let day = DateUtil.day(fromISO: date).map(Fmt.dayMonth) ?? date
        return "\(day) \(name)"
    }
}

/// The already known runs — so nothing ends up in analysis.json twice, not even if a
/// run was already entered from another source (Strava, Garmin or Polar).
struct KnownRuns: Sendable {
    private let stravaIDs: Set<String>
    private let garminIDs: Set<String>
    private let polarIDs: Set<String>
    private let distancesByDate: [String: [Double]]

    init(_ runs: [Run]) {
        stravaIDs = Set(runs.compactMap(\.stravaId))
        garminIDs = Set(runs.compactMap(\.garminId))
        polarIDs = Set(runs.compactMap(\.polarId))
        distancesByDate = Dictionary(grouping: runs, by: \.date).mapValues { $0.compactMap(\.distanceKm) }
    }

    var ids: [String] { Array(stravaIDs) }

    func contains(source: RunSource, id: String, date: String, distanceKm: Double) -> Bool {
        switch source {
        case .strava where stravaIDs.contains(id): return true
        case .garmin where garminIDs.contains(id): return true
        case .polar where polarIDs.contains(id): return true
        default: break
        }
        // Same day, almost the same distance → the same run from the other source.
        return (distancesByDate[date] ?? []).contains { abs($0 - distanceKm) <= max(0.25, distanceKm * 0.03) }
    }
}

// MARK: - Raw data → entry

enum RunImport {
    struct Lap {
        let distance: Double
        let seconds: Double
        let hr: Double?
    }

    /// From `get_activity_data` of the Garmin or Polar server (the Polar server delivers the same keys).
    static func watch(_ detail: [String: Any], source: RunSource) -> ImportedRun? {
        guard let id = stringID(detail["activityId"]),
              let summary = detail["summary"] as? [String: Any],
              let start = summary["startTimeLocal"] as? String,
              let meters = number(summary["distance"]), meters > 0 else { return nil }
        let date = String(start.prefix(10))
        let name = detail["activityName"] as? String ?? String(localized: "Run")
        let seconds = number(summary["movingDuration"]) ?? number(summary["duration"]) ?? 0
        let km = meters / 1000
        let laps = (detail["laps"] as? [[String: Any]] ?? []).map { lap in
            Lap(distance: number(lap["distance"]) ?? 0,
                seconds: number(lap["movingDuration"]) ?? number(lap["duration"]) ?? 0,
                hr: number(lap["averageHR"]))
        }
        let entry = OrderedJSON.object([
            ("source", .string(source.rawValue)),
            (source.idKey, .string(id)),
            ("sessionId", .null),
            ("name", .string(name)),
            ("date", .string(date)),
            ("distance_km", .decimal(km, digits: 2)),
            ("moving_time_s", .int(seconds)),
            ("avg_pace_s", .int(km > 0 ? seconds / km : nil)),
            ("avg_hr", .int(number(summary["averageHR"]))),
            ("max_hr", .int(number(summary["maxHR"]))),
            ("elevation_gain", .int(number(summary["elevationGain"]))),
            // Garmin and Polar count steps of both legs, Strava and the existing entries only one.
            ("cadence", .int(number(summary["averageRunCadence"]).map { $0 / 2 })),
            ("weather", garminWeather(detail["weather"] as? [String: Any], watch: number(summary["averageTemperature"])).map(OrderedJSON.string)),
            ("splits", .array(splits(laps))),
            ("verdict", .null),
            ("analysis", .null),
            ("adjustments", .null),
        ])
        return ImportedRun(entry: entry, source: source, activityID: id, date: date, name: name, distanceKm: km)
    }

    /// From `list_activities` + `get_activity_performance` of the Strava MCP.
    static func strava(_ activity: [String: Any], performance: [String: Any]) -> ImportedRun? {
        guard let id = stringID(activity["id"]),
              let start = activity["start_local"] as? String,
              let summary = activity["summary"] as? [String: Any],
              let meters = number(summary["distance"]), meters > 0 else { return nil }
        let date = String(start.prefix(10))
        let name = activity["name"] as? String ?? String(localized: "Run")
        let seconds = number(summary["moving_time"]) ?? number(summary["elapsed_time"]) ?? 0
        let km = meters / 1000
        let laps = (performance["laps"] as? [[String: Any]] ?? []).map { lap in
            Lap(distance: number(lap["distance"]) ?? 0,
                seconds: number(lap["moving_time"]) ?? number(lap["elapsed_time"]) ?? 0,
                hr: number(lap["avg_hr"]))
        }
        let entry = OrderedJSON.object([
            ("source", .string("strava")),
            ("stravaId", .string(id)),
            ("sessionId", .null),
            ("name", .string(name)),
            ("date", .string(date)),
            ("distance_km", .decimal(km, digits: 2)),
            ("moving_time_s", .int(seconds)),
            ("avg_pace_s", .int(km > 0 ? seconds / km : nil)),
            ("avg_hr", .int(number(performance["average_heartrate"]))),
            ("max_hr", .int(number(performance["max_heartrate"]))),
            ("relative_effort", .int(number(summary["relative_effort"]))),
            ("elevation_gain", .int(number(summary["elevation_gain"]))),
            ("cadence", .int(number(performance["average_cadence"]) ?? number(summary["avg_cadence"]))),
            ("splits", .array(splits(laps))),
            ("verdict", .null),
            ("analysis", .null),
            ("adjustments", .null),
        ])
        return ImportedRun(entry: entry, source: .strava, activityID: id, date: date, name: name, distanceKm: km)
    }

    /// Kilometer splits if the watch rounded automatically per kilometer, otherwise every lap
    /// individually ("Lap 3 · 800 m") — the exact naming is handled by the coach during the review.
    static func splits(_ laps: [Lap]) -> [OrderedJSON] {
        let real = laps.filter { $0.distance >= 100 && $0.seconds > 0 }
        guard !real.isEmpty else { return [] }
        let isKilometer = { (lap: Lap) in abs(lap.distance - 1000) <= 15 }
        let autoKilometers = real.dropLast().allSatisfy(isKilometer) && (isKilometer(real[real.count - 1]) || real[real.count - 1].distance < 1000)
        return real.enumerated().map { index, lap in
            let pace = OrderedJSON.int(lap.seconds / (lap.distance / 1000))
            let hr = OrderedJSON.int(lap.hr)
            if autoKilometers && isKilometer(lap) {
                return .object([("km", .number(String(index + 1))), ("pace_s", pace), ("hr", hr)])
            }
            let label = autoKilometers
                ? String(localized: "last \(distanceText(lap.distance))")
                : String(localized: "Lap \(index + 1) · \(distanceText(lap.distance))")
            return .object([("label", .string(label)), ("pace_s", pace), ("hr", hr)])
        }
    }

    /// 800 → "800 m", 2000 → "2,00 km", 130 → "0,13 km"
    static func distanceText(_ meters: Double) -> String {
        if meters >= 1000 || meters < 400 {
            return "\(Fmt.km(meters / 1000, digits: 2)) km"
        }
        return "\(Int((meters / 10).rounded()) * 10) m"
    }

    /// "Garmin weather at start: approx. 9 °C, feels like approx. 9 °C, 81 % humidity, light wind from the north;
    /// watch temperature avg 19 °C" — like the existing Garmin entries. Garmin delivers °F.
    static func garminWeather(_ weather: [String: Any]?, watch: Double?) -> String? {
        var parts: [String] = []
        if let weather, weather["error"] == nil {
            func celsius(_ key: String) -> Int? { number(weather[key]).map { Int((($0 - 32) * 5 / 9).rounded()) } }
            if let temp = celsius("temp") { parts.append(String(localized: "about \(temp) °C")) }
            if let feels = celsius("apparentTemp") { parts.append(String(localized: "feels like about \(feels) °C")) }
            if let humidity = number(weather["relativeHumidity"]) { parts.append(String(localized: "\(Int(humidity)) % humidity")) }
            if let speed = number(weather["windSpeed"]) {
                let strength = speed <= 7 ? String(localized: "light") : speed <= 15 ? String(localized: "moderate") : String(localized: "strong")
                let from = (weather["windDirectionCompassPoint"] as? String).flatMap(compassName).map { String(localized: " from \($0)") } ?? ""
                parts.append(String(localized: "\(strength) wind\(from)"))
            }
            if let description = (weather["weatherTypeDTO"] as? [String: Any])?["desc"] as? String,
               let german = weatherNames[description.lowercased()] {
                parts.append(german)
            }
        }
        var text = parts.isEmpty ? "" : String(localized: "Garmin weather at start: ") + parts.joined(separator: ", ")
        if let watch {
            text += (text.isEmpty ? "" : "; ") + String(localized: "Watch temperature avg \(Int(watch.rounded())) °C")
        }
        return text.isEmpty ? nil : text
    }

    private static let weatherNames = [
        "fair": String(localized: "fair"), "clear": String(localized: "clear"), "sunny": String(localized: "sunny"), "mostly sunny": String(localized: "mostly sunny"),
        "partly cloudy": String(localized: "partly cloudy"), "mostly cloudy": String(localized: "mostly cloudy"), "cloudy": String(localized: "cloudy"),
        "overcast": String(localized: "overcast"), "rain": String(localized: "rain"), "light rain": String(localized: "light rain"), "showers": String(localized: "showers"),
        "drizzle": String(localized: "drizzle"), "fog": String(localized: "fog"), "mist": String(localized: "mist"), "snow": String(localized: "snow"), "thunderstorm": String(localized: "thunderstorm"),
    ]

    private static func compassName(_ point: String) -> String? {
        let names = ["n": String(localized: "north"), "nne": String(localized: "north-northeast"), "ne": String(localized: "northeast"), "ene": String(localized: "east-northeast"), "e": String(localized: "east"),
                     "ese": String(localized: "east-southeast"), "se": String(localized: "southeast"), "sse": String(localized: "south-southeast"), "s": String(localized: "south"), "ssw": String(localized: "south-southwest"),
                     "sw": String(localized: "southwest"), "wsw": String(localized: "west-southwest"), "w": String(localized: "west"), "wnw": String(localized: "west-northwest"), "nw": String(localized: "northwest"),
                     "nnw": String(localized: "north-northwest")]
        return names[point.lowercased()]
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func stringID(_ value: Any?) -> String? {
        switch value {
        case let s as String: s.isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
}

// MARK: - Assignment to plan sessions

enum SessionMatcher {
    /// Unambiguous via the workout name that Garmin carries over into the run
    /// ("Stadtpark - PL W01 · 6x800m").
    static func exactMatch(name: String, in snapshot: TrainingSnapshot) -> PlannedSession? {
        snapshot.sessions.first { session in
            guard let workoutName = session.garminName else { return false }
            return name.localizedCaseInsensitiveContains(workoutName)
        }
    }

    /// Suggestions: sessions from the run's block week — open ones first, then by distance.
    static func suggestions(date: String, distanceKm: Double?, in snapshot: TrainingSnapshot) -> [PlannedSession] {
        guard let day = DateUtil.day(fromISO: date), let week = snapshot.blockWeek(containing: day) else { return [] }
        let german = DateUtil.germanDay(day)
        return snapshot.sessions(inWeek: week).sorted { a, b in
            let openA = !snapshot.isDone(a) || snapshot.doneDate(a) == german
            let openB = !snapshot.isDone(b) || snapshot.doneDate(b) == german
            if openA != openB { return openA }
            guard let distanceKm else { return a.index < b.index }
            return abs(a.plannedKm - distanceKm) < abs(b.plannedKm - distanceKm)
        }
    }
}

// MARK: - Writing analysis.json

enum AnalysisWriter {
    /// Puts new runs at the start of the list (newest first, as described in the README).
    static func insert(_ runs: [ImportedRun], in folder: ProjectFolder) throws {
        guard !runs.isEmpty else { return }
        let url = folder.file(TrainingFiles.analysis)
        var document = try JSONDocument(contentsOf: url, style: .python)
        let existing = document.root["runs"]?.arrayValue ?? []
        let fresh = runs.sorted { $0.date > $1.date }.map(\.entry)
        document.root["runs"] = .array(fresh + existing)
        try document.write(to: url)
    }

    /// Assigns a run to a plan session (or removes the assignment with `nil`).
    static func assign(runID: String, to sessionID: String?, in folder: ProjectFolder) throws {
        let url = folder.file(TrainingFiles.analysis)
        var document = try JSONDocument(contentsOf: url, style: .python)
        guard var runs = document.root["runs"]?.arrayValue,
              let index = runs.firstIndex(where: { identity(of: $0) == runID }) else {
            throw StoreError.missingFile(String(localized: "Run \(runID) in analysis.json"))
        }
        runs[index]["sessionId"] = sessionID.map(OrderedJSON.string) ?? .null
        document.root["runs"] = .array(runs)
        try document.write(to: url)
    }

    /// The same ID as `Run.id`.
    private static func identity(of entry: OrderedJSON) -> String? {
        if let id = entry["stravaId"]?.stringValue { return id }
        if let id = entry["garminId"]?.stringValue { return id }
        if let id = entry["polarId"]?.stringValue { return id }
        guard let date = entry["date"]?.stringValue, let name = entry["name"]?.stringValue else { return nil }
        return "\(date)-\(name)"
    }
}
