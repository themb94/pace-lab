import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Markenfarbe (Orange).
    static let brand = Color(hex: 0xFC4C02)

    /// Seitenhintergrund hinter den Karten.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    /// Hintergrund einer Karte.
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    /// Dezente Füllung für Kacheln und Chips innerhalb einer Karte.
    static var subtleFill: Color { Color.primary.opacity(0.06) }
}

extension SessionType {
    var label: String {
        switch self {
        case .tempo: "Tempo"
        case .easy: "Locker"
        case .long: "Long Run"
        case .race: "Rennen"
        }
    }

    /// Kurzform ("TEMPO", "LOCKER", "LONG").
    var shortLabel: String {
        switch self {
        case .tempo: "TEMPO"
        case .easy: "LOCKER"
        case .long: "LONG"
        case .race: "RENNEN"
        }
    }

    var symbol: String {
        switch self {
        case .tempo: "bolt.fill"
        case .easy: "leaf.fill"
        case .long: "road.lanes"
        case .race: "flag.checkered"
        }
    }

    var color: Color {
        switch self {
        case .tempo: Color(hex: 0xFF5A52)
        case .easy: Color(hex: 0x2EB866)
        case .long: Color(hex: 0x3D8BFF)
        case .race: .brand
        }
    }
}

extension Verdict {
    var label: String {
        switch self {
        case .gut: "Gut gelaufen"
        case .ok: "Solide"
        case .achtung: "Beachten"
        }
    }

    var symbol: String {
        switch self {
        case .gut: "checkmark.seal.fill"
        case .ok: "hand.thumbsup.fill"
        case .achtung: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .gut: Color(hex: 0x2EB866)
        case .ok: Color(hex: 0x3D8BFF)
        case .achtung: Color(hex: 0xE0A800)
        }
    }
}

enum HRZone {
    /// Zonenfarben (Z1 grau … Z5 rot).
    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1: Color(hex: 0x7A8699)
        case 2: Color(hex: 0x2ECC71)
        case 3: Color(hex: 0xF5C518)
        case 4: Color(hex: 0xFF8C42)
        default: Color(hex: 0xFF5252)
        }
    }
}

enum PhaseStyle {
    static func color(_ phase: String) -> Color {
        switch phase.lowercased() {
        case "aufbau": Color(hex: 0x2EB866)
        case "step-back": Color(hex: 0xE0A800)
        case "peak": Color(hex: 0xB065E0)
        case "taper": Color(hex: 0xFF8C42)
        case "basis": Color(hex: 0x3D8BFF)
        case "race": .brand
        default: .secondary
        }
    }
}
