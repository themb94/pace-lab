import Foundation

enum DateUtil {
    /// Gregorianisch, Woche beginnt Montag, lokale Zeitzone.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Fmt.locale
        return c
    }()

    /// "2026-09-28" → Tagesbeginn
    static func day(fromISO text: String) -> Date? {
        let p = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "28.09.2026" → Tagesbeginn
    static func day(fromGerman text: String) -> Date? {
        let p = text.split(separator: ".").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[2], month: p[1], day: p[0]))
    }

    /// Tagesbeginn → "2026-09-28" (Format von plan.json / analysis.json)
    static func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Tagesbeginn → "28.09.2026" (Format von completed.json)
    static func germanDay(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    static func startOfWeek(_ date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day) // 1 = So … 7 = Sa
        let back = (weekday + 5) % 7                            // Mo → 0, So → 6
        return calendar.date(byAdding: .day, value: -back, to: day)!
    }

    /// Ganze Tage zwischen zwei Daten (auf Tagesbeginn normiert).
    static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}

/// Sprache der App: die beste Übereinstimmung aus den Systemsprachen und den Übersetzungen (Deutsch bzw. Englisch).
enum AppLanguage {
    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var isGerman: Bool { code == "de" }
}

enum Fmt {
    /// Zahlen, Daten und Wochentage richten sich nach den Systemeinstellungen (Sprache und Region).
    static let locale = Locale.autoupdatingCurrent

    /// 350 → "5:50"
    static func pace(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 5400 → "1:30:00", 2750 → "45:50"
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 21.13 → "21.1" (en) bzw. "21,1" (de)
    static func km(_ value: Double?, digits: Int = 1) -> String {
        (value ?? 0).formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    static func int(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(Int(value.rounded()))
    }

    /// "20.09."
    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(locale))
    }

    /// "So., 20.09."
    static func weekdayDayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day(.twoDigits).month(.twoDigits).locale(locale))
    }

    /// "Sonntag, 20. September 2026"
    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(locale))
    }

    /// "September 2026"
    static func monthYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(locale))
    }

    /// "28.09.–04.10."
    static func range(_ start: Date, _ end: Date) -> String {
        "\(dayMonth(start))–\(dayMonth(end))"
    }

    /// "in 4 Tagen" / "morgen" / "heute"
    static func relativeDays(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "today")
        case 1: String(localized: "tomorrow")
        default: String(localized: "in \(days) days")
        }
    }
}
