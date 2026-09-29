import Foundation

/// Woher die App neue Läufe holt (Einstellungen → Läufe).
enum RunSource: String, CaseIterable, Identifiable, Sendable {
    case garmin, strava

    var id: String { rawValue }

    var label: String {
        switch self {
        case .garmin: "Garmin Connect (direkt)"
        case .strava: "Strava (über Claude Code)"
        }
    }

    var shortLabel: String {
        switch self {
        case .garmin: "Garmin"
        case .strava: "Strava"
        }
    }
}

/// Ein neu geladener Lauf, fertig als Eintrag für analysis.json — noch ohne Bewertung und Analyse.
struct ImportedRun: Sendable {
    private(set) var entry: OrderedJSON
    let source: RunSource
    /// Aktivitäts-ID bei der Quelle.
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

    /// „29.09. 6x800m“ für Verlauf und Meldungen.
    var shortDescription: String {
        let day = DateUtil.day(fromISO: date).map(Fmt.dayMonth) ?? date
        return "\(day) \(name)"
    }
}

/// Die schon bekannten Läufe — damit nichts doppelt in analysis.json landet, auch nicht, wenn ein
/// Lauf schon von der anderen Quelle (Strava bzw. Garmin) eingetragen wurde.
struct KnownRuns: Sendable {
    private let stravaIDs: Set<String>
    private let garminIDs: Set<String>
    private let distancesByDate: [String: [Double]]

    init(_ runs: [Run]) {
        stravaIDs = Set(runs.compactMap(\.stravaId))
        garminIDs = Set(runs.compactMap(\.garminId))
        distancesByDate = Dictionary(grouping: runs, by: \.date).mapValues { $0.compactMap(\.distanceKm) }
    }

    var ids: [String] { Array(stravaIDs) }

    func contains(source: RunSource, id: String, date: String, distanceKm: Double) -> Bool {
        switch source {
        case .strava where stravaIDs.contains(id): return true
        case .garmin where garminIDs.contains(id): return true
        default: break
        }
        // Gleicher Tag, fast gleiche Distanz → derselbe Lauf aus der anderen Quelle.
        return (distancesByDate[date] ?? []).contains { abs($0 - distanceKm) <= max(0.25, distanceKm * 0.03) }
    }
}

// MARK: - Rohdaten → Eintrag

enum RunImport {
    struct Lap {
        let distance: Double
        let seconds: Double
        let hr: Double?
    }

    /// Aus `get_activity_data` des Garmin-Servers.
    static func garmin(_ detail: [String: Any]) -> ImportedRun? {
        guard let id = stringID(detail["activityId"]),
              let summary = detail["summary"] as? [String: Any],
              let start = summary["startTimeLocal"] as? String,
              let meters = number(summary["distance"]), meters > 0 else { return nil }
        let date = String(start.prefix(10))
        let name = detail["activityName"] as? String ?? "Lauf"
        let seconds = number(summary["movingDuration"]) ?? number(summary["duration"]) ?? 0
        let km = meters / 1000
        let laps = (detail["laps"] as? [[String: Any]] ?? []).map { lap in
            Lap(distance: number(lap["distance"]) ?? 0,
                seconds: number(lap["movingDuration"]) ?? number(lap["duration"]) ?? 0,
                hr: number(lap["averageHR"]))
        }
        let entry = OrderedJSON.object([
            ("source", .string("garmin")),
            ("garminId", .string(id)),
            ("sessionId", .null),
            ("name", .string(name)),
            ("date", .string(date)),
            ("distance_km", .decimal(km, digits: 2)),
            ("moving_time_s", .int(seconds)),
            ("avg_pace_s", .int(km > 0 ? seconds / km : nil)),
            ("avg_hr", .int(number(summary["averageHR"]))),
            ("max_hr", .int(number(summary["maxHR"]))),
            ("elevation_gain", .int(number(summary["elevationGain"]))),
            // Garmin zählt Schritte beider Beine, Strava und die bisherigen Einträge nur eines.
            ("cadence", .int(number(summary["averageRunCadence"]).map { $0 / 2 })),
            ("weather", garminWeather(detail["weather"] as? [String: Any], watch: number(summary["averageTemperature"])).map(OrderedJSON.string)),
            ("splits", .array(splits(laps))),
            ("verdict", .null),
            ("analysis", .null),
            ("adjustments", .null),
        ])
        return ImportedRun(entry: entry, source: .garmin, activityID: id, date: date, name: name, distanceKm: km)
    }

    /// Aus `list_activities` + `get_activity_performance` des Strava-MCP.
    static func strava(_ activity: [String: Any], performance: [String: Any]) -> ImportedRun? {
        guard let id = stringID(activity["id"]),
              let start = activity["start_local"] as? String,
              let summary = activity["summary"] as? [String: Any],
              let meters = number(summary["distance"]), meters > 0 else { return nil }
        let date = String(start.prefix(10))
        let name = activity["name"] as? String ?? "Lauf"
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

    /// Kilometer-Splits, wenn die Uhr automatisch pro Kilometer gerundet hat, sonst jede Runde
    /// einzeln („Runde 3 · 800 m“) — die genaue Benennung übernimmt der Coach bei der Auswertung.
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
                ? "letzte \(distanceText(lap.distance))"
                : "Runde \(index + 1) · \(distanceText(lap.distance))"
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

    /// „Garmin-Wetter beim Start: ca. 9 °C, gefühlt ca. 9 °C, 81 % Luftfeuchte, schwacher Wind aus Nord;
    /// Uhrtemperatur Ø 19 °C“ — wie die bisherigen Garmin-Einträge. Garmin liefert °F.
    static func garminWeather(_ weather: [String: Any]?, watch: Double?) -> String? {
        var parts: [String] = []
        if let weather, weather["error"] == nil {
            func celsius(_ key: String) -> Int? { number(weather[key]).map { Int((($0 - 32) * 5 / 9).rounded()) } }
            if let temp = celsius("temp") { parts.append("ca. \(temp) °C") }
            if let feels = celsius("apparentTemp") { parts.append("gefühlt ca. \(feels) °C") }
            if let humidity = number(weather["relativeHumidity"]) { parts.append("\(Int(humidity)) % Luftfeuchte") }
            if let speed = number(weather["windSpeed"]) {
                let strength = speed <= 7 ? "schwacher" : speed <= 15 ? "mäßiger" : "starker"
                let from = (weather["windDirectionCompassPoint"] as? String).flatMap(compassName).map { " aus \($0)" } ?? ""
                parts.append("\(strength) Wind\(from)")
            }
            if let description = (weather["weatherTypeDTO"] as? [String: Any])?["desc"] as? String,
               let german = weatherNames[description.lowercased()] {
                parts.append(german)
            }
        }
        var text = parts.isEmpty ? "" : "Garmin-Wetter beim Start: " + parts.joined(separator: ", ")
        if let watch {
            text += (text.isEmpty ? "" : "; ") + "Uhrtemperatur Ø \(Int(watch.rounded())) °C"
        }
        return text.isEmpty ? nil : text
    }

    private static let weatherNames = [
        "fair": "heiter", "clear": "klar", "sunny": "sonnig", "mostly sunny": "überwiegend sonnig",
        "partly cloudy": "teils bewölkt", "mostly cloudy": "überwiegend bewölkt", "cloudy": "bewölkt",
        "overcast": "bedeckt", "rain": "Regen", "light rain": "leichter Regen", "showers": "Schauer",
        "drizzle": "Nieselregen", "fog": "Nebel", "mist": "Dunst", "snow": "Schnee", "thunderstorm": "Gewitter",
    ]

    private static func compassName(_ point: String) -> String? {
        let names = ["n": "Nord", "nne": "Nordnordost", "ne": "Nordost", "ene": "Ostnordost", "e": "Ost",
                     "ese": "Ostsüdost", "se": "Südost", "sse": "Südsüdost", "s": "Süd", "ssw": "Südsüdwest",
                     "sw": "Südwest", "wsw": "Westsüdwest", "w": "West", "wnw": "Westnordwest", "nw": "Nordwest",
                     "nnw": "Nordnordwest"]
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

// MARK: - Zuordnung zu Plan-Einheiten

enum SessionMatcher {
    /// Eindeutig über den Workout-Namen, den Garmin in den Lauf übernimmt
    /// („Stadtpark - PL W01 · 6x800m“).
    static func exactMatch(name: String, in snapshot: TrainingSnapshot) -> PlannedSession? {
        snapshot.sessions.first { session in
            guard let workoutName = session.garminName else { return false }
            return name.localizedCaseInsensitiveContains(workoutName)
        }
    }

    /// Vorschläge: Einheiten aus der Blockwoche des Laufs — offene zuerst, dann nach Distanz.
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

// MARK: - analysis.json schreiben

enum AnalysisWriter {
    /// Stellt neue Läufe an den Anfang der Liste (neueste zuerst, wie in der README beschrieben).
    static func insert(_ runs: [ImportedRun], in folder: ProjectFolder) throws {
        guard !runs.isEmpty else { return }
        let url = folder.file(TrainingFiles.analysis)
        var document = try JSONDocument(contentsOf: url, style: .python)
        let existing = document.root["runs"]?.arrayValue ?? []
        let fresh = runs.sorted { $0.date > $1.date }.map(\.entry)
        document.root["runs"] = .array(fresh + existing)
        try document.write(to: url)
    }

    /// Ordnet einen Lauf einer Plan-Einheit zu (oder löst die Zuordnung mit `nil`).
    static func assign(runID: String, to sessionID: String?, in folder: ProjectFolder) throws {
        let url = folder.file(TrainingFiles.analysis)
        var document = try JSONDocument(contentsOf: url, style: .python)
        guard var runs = document.root["runs"]?.arrayValue,
              let index = runs.firstIndex(where: { identity(of: $0) == runID }) else {
            throw StoreError.missingFile("Lauf \(runID) in analysis.json")
        }
        runs[index]["sessionId"] = sessionID.map(OrderedJSON.string) ?? .null
        document.root["runs"] = .array(runs)
        try document.write(to: url)
    }

    /// Dieselbe ID wie `Run.id`.
    private static func identity(of entry: OrderedJSON) -> String? {
        if let id = entry["stravaId"]?.stringValue { return id }
        if let id = entry["garminId"]?.stringValue { return id }
        guard let date = entry["date"]?.stringValue, let name = entry["name"]?.stringValue else { return nil }
        return "\(date)-\(name)"
    }
}
