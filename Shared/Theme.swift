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

    /// A color with its own value for the light and the dark appearance.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #endif
    }

    /// Brand color (orange) — the app's own mark (icon, coach, profiles). Not a status or an intensity:
    /// those have their own colors below.
    static let brand = Color(hex: 0xFC4C02)

    /// Page background behind the cards.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    /// Background of a card.
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    /// Subtle fill for tiles and chips inside a card.
    static var subtleFill: Color { Color.primary.opacity(0.06) }
}

/// For colored text and symbols: saturated colors reach only ~2–3:1 on a light background, so in the
/// light appearance they are darkened (≥ 4.5:1 on white); in the dark appearance they stay as they are.
struct LegibleStyle: ShapeStyle {
    let base: Color

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let color = base.resolve(in: environment)
        guard environment.colorScheme == .light else { return color }
        let keep: Float = 0.6
        return Color.Resolved(red: color.red * keep, green: color.green * keep, blue: color.blue * keep,
                              opacity: color.opacity)
    }
}

extension ShapeStyle where Self == LegibleStyle {
    static func legible(_ color: Color) -> LegibleStyle { LegibleStyle(base: color) }
}

extension SessionType {
    var label: String {
        switch self {
        case .tempo: "Tempo"
        case .easy: String(localized: "Easy")
        case .long: "Long Run"
        case .race: String(localized: "Race")
        }
    }

    /// Short form ("Tempo", "Easy", "Long").
    var shortLabel: String {
        switch self {
        case .long: "Long"
        default: label
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

    /// Heart-rate zone the session is meant for: easy and long runs in zone 2, tempo in 4, the race in 5.
    var zone: Int {
        switch self {
        case .easy, .long: 2
        case .tempo: 4
        case .race: 5
        }
    }

    /// The color of the intensity — the same scale as the heart-rate zones.
    var color: Color { HRZone.color(zone) }
}

extension Verdict {
    var label: String {
        switch self {
        case .gut: String(localized: "Went well")
        case .ok: String(localized: "Solid")
        case .achtung: String(localized: "Needs attention")
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

/// Intensity is the one color scale of the app: the heart-rate zones (Z1 gray … Z5 red). Session types,
/// splits and zone legends all use it, so a color always means "how hard". Light values are darker so that
/// bars reach at least 3:1 on white.
enum HRZone {
    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1: Color(light: 0x6B7585, dark: 0x7A8699)
        case 2: Color(light: 0x1E9E52, dark: 0x2ECC71)
        case 3: Color(light: 0xB8900A, dark: 0xF5C518)
        case 4: Color(light: 0xE0701F, dark: 0xFF8C42)
        default: Color(light: 0xE03E3E, dark: 0xFF5252)
        }
    }
}

extension Font {
    /// Numbers (km, pace, time, heart rate): SF Pro Expanded with digits of equal width — the look of a
    /// start number or a stopwatch. Only for figures; everything else stays in the regular system font.
    static func figures(_ style: Font.TextStyle = .body, weight: Font.Weight = .semibold) -> Font {
        .system(style, weight: weight).width(.expanded).monospacedDigit()
    }

    static func figures(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded).monospacedDigit()
    }
}
