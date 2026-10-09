import Foundation

/// Titles of the history entries (git commits): they are created in the app's language. German and
/// English titles are both recognized, so that older entries and a language change don't mix up the history.
enum HistorySubject {
    enum Kind {
        case coach, checkedOff, unchecked, runsLoaded, assigned, undone, plan, initial, external, other
    }

    static func kind(of subject: String) -> Kind {
        func has(_ prefixes: String...) -> Bool { prefixes.contains { subject.hasPrefix($0) } }
        if has("Coach") { return .coach }
        if has("Abgehakt", "Checked off") { return .checkedOff }
        if has("Häkchen", "Unchecked") { return .unchecked }
        if subject.contains("geladen") || subject.contains("loaded") { return .runsLoaded }
        if has("Zugeordnet", "Assigned") { return .assigned }
        if has("Rückgängig", "Undone") { return .undone }
        if has("Neuer Block", "Entwurf", "Vorschlag", "New block", "Draft", "Suggestion") { return .plan }
        if has("Ausgangsstand", "Initial state") { return .initial }
        if has("Änderungen außerhalb der App", "Changes outside the app") { return .external }
        return .other
    }
}
