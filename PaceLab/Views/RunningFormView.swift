import SwiftUI

/// Garmin's running dynamics of a run (“Laufeffizienz” in Garmin's German apps): the values on Garmin's
/// color scale, how the form changes during the run, starting points to work on — and the way to the
/// coach, who compares with the athlete's own runs and writes recommendations into `running_form`.
struct RunningFormSection: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let dynamics: RunningDynamics

    var body: some View {
        let drift = FormDrift(splits: run.splits ?? [])
        let hints = FormHints.make(dynamics, drift: drift)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Running dynamics"))
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(FormValue.all(dynamics)) { item in
                        FormTile(item: item)
                    }
                }
                if let drift {
                    Label(drift.text, systemImage: "arrow.right.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starting points")
                        .font(.callout.weight(.semibold))
                    if hints.isEmpty {
                        Text("Nothing stands out on Garmin’s scale.")
                    } else {
                        ForEach(hints, id: \.self) { hint in
                            Label(hint, systemImage: "figure.run")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                HStack(alignment: .top, spacing: 12) {
                    Text("Colors follow Garmin’s scale, a comparison with other runners. At an easy pace a lower cadence and longer ground contact are normal — what counts is the comparison with your own runs at a similar pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.askCoachAboutForm(of: run)
                    } label: {
                        Label("Tips from the coach", systemImage: "sparkles")
                    }
                    .help(String(localized: "Let the coach look at your running form and recommend what to work on"))
                }
            }
            .card()
        }
    }
}

// MARK: - Garmin's scale

/// Garmin's color gauge for running dynamics — a comparison with other runners in percentiles
/// (purple > 95, blue 70–95, green 30–69, orange 5–29, red < 5), limits from the watch manuals for a
/// chest sensor such as the HRM-Pro.
enum FormRating: Int, Comparable, Sendable {
    case poor, fair, average, good, excellent

    static func < (lhs: FormRating, rhs: FormRating) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .excellent: String(localized: "excellent")
        case .good: String(localized: "good")
        case .average: String(localized: "average")
        case .fair: String(localized: "below average")
        case .poor: String(localized: "poor")
        }
    }

    /// Garmin rates the balance only as even (green), slightly (orange) or clearly uneven (red).
    var balanceLabel: String {
        switch self {
        case .excellent, .good, .average: String(localized: "even")
        case .fair: String(localized: "slightly uneven")
        case .poor: String(localized: "uneven")
        }
    }

    var color: Color {
        switch self {
        case .excellent: Color.purple
        case .good: Color.blue
        case .average: Color.green
        case .fair: Color.orange
        case .poor: Color.red
        }
    }

    /// Orange or red: worth working on.
    var needsWork: Bool { self <= .fair }

    /// Rating from the lower limits of purple, blue, green and orange — in both directions: if `best` is the
    /// smallest limit, lower values are better (ground contact), otherwise higher ones (cadence).
    static func rate(_ value: Double, best: Double, good: Double, average: Double, fair: Double) -> FormRating {
        let higherIsBetter = best > fair
        func reaches(_ limit: Double) -> Bool { higherIsBetter ? value >= limit : value <= limit }
        if reaches(best) { return .excellent }
        if reaches(good) { return .good }
        if reaches(average) { return .average }
        if reaches(fair) { return .fair }
        return .poor
    }
}

extension Run {
    /// Running dynamics worth a section of their own — more than the cadence every watch measures.
    var measuredDynamics: RunningDynamics? {
        guard let d = runningDynamics,
              [d.strideLengthCm, d.groundContactMs, d.gctBalanceLeftPct, d.verticalOscillationCm, d.verticalRatioPct]
                .contains(where: { $0 != nil }) else { return nil }
        return d
    }
}

extension RunningDynamics {
    var cadenceRating: FormRating? {
        cadenceSpm.map { spm -> FormRating in
            FormRating.rate(spm.rounded(), best: 184, good: 174, average: 164, fair: 153)
        }
    }

    var groundContactRating: FormRating? {
        groundContactMs.map { ms -> FormRating in
            FormRating.rate(ms.rounded(), best: 217, good: 248, average: 277, fair: 308)
        }
    }

    /// In tenths of a centimeter, so that the limits are exact.
    var verticalOscillationRating: FormRating? {
        verticalOscillationCm.map { cm -> FormRating in
            FormRating.rate((cm * 10).rounded(), best: 63, good: 81, average: 97, fair: 115)
        }
    }

    /// In tenths of a percent.
    var verticalRatioRating: FormRating? {
        verticalRatioPct.map { ratio -> FormRating in
            FormRating.rate((ratio * 10).rounded(), best: 60, good: 74, average: 86, fair: 101)
        }
    }

    /// Green up to 50.7 % on one side, orange up to 52.2 %, red beyond.
    var balanceRating: FormRating? {
        gctBalanceLeftPct.map { left -> FormRating in
            let off = abs((left * 10).rounded() - 500)
            if off <= 7 { return .average }
            return off <= 22 ? .fair : .poor
        }
    }
}

// MARK: - Values, course of the run, starting points

/// One value of the running dynamics in a tile.
private struct FormValue: Identifiable {
    let label: String
    let value: String
    var rating: FormRating? = nil
    var ratingText: String? = nil

    var id: String { label }

    static func all(_ d: RunningDynamics) -> [FormValue] {
        var values: [FormValue] = []
        if let spm = d.cadenceSpm {
            values.append(FormValue(label: String(localized: "Cadence"), value: "\(Fmt.int(spm)) spm", rating: d.cadenceRating))
        }
        if let cm = d.strideLengthCm {
            // Garmin has no scale for the stride length: it depends on height and pace.
            values.append(FormValue(label: String(localized: "Stride length"), value: "\(Fmt.km(cm / 100, digits: 2)) m"))
        }
        if let ms = d.groundContactMs {
            values.append(FormValue(label: String(localized: "Ground contact"), value: "\(Fmt.int(ms)) ms", rating: d.groundContactRating))
        }
        if let left = d.gctBalanceLeftPct {
            values.append(FormValue(label: String(localized: "Balance L/R"),
                                    value: "\(Fmt.km(left, digits: 1)) / \(Fmt.km(100 - left, digits: 1)) %",
                                    rating: d.balanceRating, ratingText: d.balanceRating?.balanceLabel))
        }
        if let cm = d.verticalOscillationCm {
            values.append(FormValue(label: String(localized: "Vertical oscillation"), value: "\(Fmt.km(cm, digits: 1)) cm", rating: d.verticalOscillationRating))
        }
        if let ratio = d.verticalRatioPct {
            values.append(FormValue(label: String(localized: "Vertical ratio"), value: "\(Fmt.km(ratio, digits: 1)) %", rating: d.verticalRatioRating))
        }
        return values
    }
}

private struct FormTile: View {
    let item: FormValue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let rating = item.rating {
                    Circle().fill(rating.color).frame(width: 7, height: 7)
                    Text(item.ratingText ?? rating.label).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            Text(item.value)
                .font(.figures(.title3))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How the form changes from the first to the last third of a run's kilometer splits (not for intervals,
/// where the laps differ on purpose).
struct FormDrift {
    let pace: (from: Double, to: Double)
    let contact: (from: Double, to: Double)?
    let strideLength: (from: Double, to: Double)?

    init?(splits: [Split]) {
        let kilometers = splits.filter { $0.km != nil && $0.paceS > 0 }
        guard kilometers.count >= 6 else { return nil }
        let first = Array(kilometers.prefix(kilometers.count / 3))
        let last = Array(kilometers.suffix(kilometers.count / 3))
        func change(_ value: (Split) -> Double?) -> (from: Double, to: Double)? {
            guard let from = FormDrift.mean(first.map(value)), let to = FormDrift.mean(last.map(value)) else { return nil }
            return (from, to)
        }
        guard let pace = change({ $0.paceS }) else { return nil }
        self.pace = pace
        contact = change { $0.groundContactMs }
        strideLength = change { $0.strideLengthCm }
        guard contact != nil || strideLength != nil else { return nil }
    }

    /// Mean if every split has the value.
    private static func mean(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty, present.count == values.count else { return nil }
        return present.reduce(0, +) / Double(present.count)
    }

    /// Ground contact at least 4 % longer in the last third — the form fades with fatigue.
    var contactRise: Double? {
        guard let contact, contact.from > 0 else { return nil }
        let rise = contact.to / contact.from - 1
        return rise >= 0.04 ? rise : nil
    }

    /// "First → last third: ground contact 245 → 262 ms · stride 1.10 → 1.04 m · pace 5:40 → 5:45"
    var text: String {
        var parts: [String] = []
        if let contact {
            parts.append(String(localized: "ground contact \(Fmt.int(contact.from)) → \(Fmt.int(contact.to)) ms"))
        }
        if let strideLength {
            parts.append(String(localized: "stride \(Fmt.km(strideLength.from / 100, digits: 2)) → \(Fmt.km(strideLength.to / 100, digits: 2)) m"))
        }
        parts.append(String(localized: "pace \(Fmt.pace(pace.from)) → \(Fmt.pace(pace.to))"))
        return String(localized: "First → last third: ") + parts.joined(separator: " · ")
    }
}

/// Starting points from Garmin's scale and the course of the run — general advice; the coach adds the
/// personal view (pace, type of run, earlier runs).
enum FormHints {
    static func make(_ d: RunningDynamics, drift: FormDrift?) -> [String] {
        var hints: [String] = []
        if d.cadenceRating?.needsWork == true {
            hints.append(String(localized: "Cadence: shorter, quicker steps — raise it gradually (about 5 percent at a time), e.g. with a metronome or music to the beat; strides help."))
        }
        if d.groundContactRating?.needsWork == true {
            hints.append(String(localized: "Ground contact: push off more reactively — running drills (skips, ankle work), rope skipping and strides train it."))
        }
        if d.verticalOscillationRating?.needsWork == true || d.verticalRatioRating?.needsWork == true {
            hints.append(String(localized: "Vertical motion: less bouncing, more forward — run tall with a slight lean from the ankles; a higher cadence usually lowers the bounce by itself."))
        }
        if d.balanceRating?.needsWork == true {
            hints.append(String(localized: "Balance: left and right carry unevenly — single-leg strength work (lunges, single-leg squats, calf raises) evens it out; have pain checked by a doctor or physiotherapist."))
        }
        if let rise = drift?.contactRise {
            hints.append(String(localized: "Towards the end the ground contact gets \(Int((rise * 100).rounded())) % longer — the form fades with fatigue: strength work for core and legs twice a week and drills after easy runs help."))
        }
        return hints
    }
}
