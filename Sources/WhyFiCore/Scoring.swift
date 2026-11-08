import Foundation

/// A channel the user could set their AP to.
public struct Candidate: Sendable, Hashable {
    public var band: Band
    public var primary: Int
    public var width: ChannelWidth

    public init(band: Band, primary: Int, width: ChannelWidth) {
        self.band = band
        self.primary = primary
        self.width = width
    }
}

public enum Grade: String, Codable, Sendable, Comparable, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D", f = "F"

    init(noiseRiseDB: Double) {
        switch noiseRiseDB {
        case ..<3: self = .a
        case ..<8: self = .b
        case ..<15: self = .c
        case ..<25: self = .d
        default: self = .f
        }
    }

    public static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
}

public struct ChannelScore: Codable, Sendable, Identifiable, Hashable {
    public var spec: ChannelSpec
    /// Overlap-weighted sum of neighbour power landing in the passband; nil if none.
    public var interferenceDBm: Double?
    /// How far that interference raises the noise floor.
    public var noiseRiseDB: Double
    /// Overlapping BSSes loud enough (≥ −82 dBm) to make an AP here defer.
    public var contenders: Int
    /// Highest advertised BSS Load channel utilization among overlapping BSSes.
    public var utilization: Double?
    /// Total overlapping BSSes regardless of strength.
    public var overlapping: Int
    public var isDFS: Bool
    public var isPSC: Bool
    public var grade: Grade
    /// For time-averaged scores: 90th-percentile noise rise (how bad it gets when neighbours are busy).
    public var peakNoiseRiseDB: Double?
    /// Sweeps the score is based on.
    public var samples = 1

    public var id: ChannelSpec { spec }
}

extension ChannelScore {
    /// Tolerates fields added after a location was saved, so old `locations.json` files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(ChannelSpec.self, forKey: .spec)
        interferenceDBm = try c.decodeIfPresent(Double.self, forKey: .interferenceDBm)
        noiseRiseDB = try c.decode(Double.self, forKey: .noiseRiseDB)
        contenders = try c.decodeIfPresent(Int.self, forKey: .contenders) ?? 0
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        overlapping = try c.decodeIfPresent(Int.self, forKey: .overlapping) ?? 0
        isDFS = try c.decodeIfPresent(Bool.self, forKey: .isDFS) ?? false
        isPSC = try c.decodeIfPresent(Bool.self, forKey: .isPSC) ?? false
        grade = try c.decodeIfPresent(Grade.self, forKey: .grade) ?? Grade(noiseRiseDB: noiseRiseDB)
        peakNoiseRiseDB = try c.decodeIfPresent(Double.self, forKey: .peakNoiseRiseDB)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 1
    }
}

public struct Interferer: Sendable {
    public var id: String
    public var spec: ChannelSpec
    public var rssi: Double
    public var utilization: Double?

    public init(id: String = "", spec: ChannelSpec, rssi: Double, utilization: Double?) {
        self.id = id
        self.spec = spec
        self.rssi = rssi
        self.utilization = utilization
    }
}

public enum Scorer {
    public static let contenderThresholdDBm = -82.0
    /// Noise floor of a 20 MHz channel; wider channels scale it by bandwidth.
    public static let defaultNoiseFloorDBm = -95.0

    /// `noiseFloorDBm` is per 20 MHz. A wider receiver collects proportionally more thermal noise, so the same
    /// neighbour raises a 160 MHz channel's floor less than a 20 MHz one's.
    static func noiseFloor(_ per20: Double, for spec: ChannelSpec) -> Double {
        per20 + 10 * log10(max(spec.totalMHz, 20) / 20)
    }

    struct Measurement {
        var interferenceDBm: Double?
        var noiseRiseDB: Double
        var contenders: Int
        var overlapping: Int
        var utilization: Double?
    }

    static func measure(_ spec: ChannelSpec, against interferers: [Interferer], floorDBm: Double) -> Measurement {
        var power = 0.0   // mW
        var contenders = 0, overlapping = 0
        var utilization: Double?
        for i in interferers where i.spec.band == spec.band {
            let f = i.spec.fraction(inside: spec)
            guard f > 0 else { continue }
            overlapping += 1
            power += pow(10, i.rssi / 10) * f
            if i.rssi >= contenderThresholdDBm { contenders += 1 }
            if let u = i.utilization { utilization = max(utilization ?? 0, u) }
        }
        let iDBm = power > 0 ? 10 * log10(power) : nil
        // Proper noise rise: (I + N) / N, so weak interference near the floor still counts a little.
        let rise = power > 0 ? 10 * log10(power + pow(10, floorDBm / 10)) - floorDBm : 0
        return Measurement(interferenceDBm: iDBm, noiseRiseDB: rise, contenders: contenders,
                           overlapping: overlapping, utilization: utilization)
    }

    public static func score(_ spec: ChannelSpec, against interferers: [Interferer], noiseFloorDBm: Double) -> ChannelScore {
        let m = measure(spec, against: interferers, floorDBm: noiseFloor(noiseFloorDBm, for: spec))
        return ChannelScore(spec: spec, interferenceDBm: m.interferenceDBm, noiseRiseDB: m.noiseRiseDB,
                            contenders: m.contenders, utilization: m.utilization, overlapping: m.overlapping,
                            isDFS: spec.coveredChannels.contains { ChannelPlan.isDFS(band: spec.band, channel: $0) },
                            isPSC: ChannelPlan.isPSC(band: spec.band, channel: spec.primary),
                            grade: Grade(noiseRiseDB: m.noiseRiseDB))
    }

    /// Which candidates are worth recommending: 1/6/11 at 20 MHz on 2.4 GHz, PSC primaries on 6 GHz,
    /// one entry per distinct block (a 160 MHz block appears once, not eight times).
    public static func recommendable(_ candidates: [Candidate]) -> [ChannelSpec] {
        var seen = Set<[ClosedRange<Double>]>()
        var out: [ChannelSpec] = []
        for c in candidates.sorted(by: { ($0.band, $0.width, $0.primary) < ($1.band, $1.width, $1.primary) })
        where ChannelPlan.isValid(band: c.band, primary: c.primary, width: c.width) {
            switch c.band {
            case .ghz2_4: guard c.width == .w20, [1, 6, 11].contains(c.primary) else { continue }
            case .ghz5: break
            case .ghz6: guard ChannelPlan.isPSC(band: .ghz6, channel: c.primary) else { continue }
            }
            let spec = ChannelPlan.spec(band: c.band, primary: c.primary, width: c.width)
            let key = spec.segments.map { $0 } // band is implied by frequency
            if seen.insert(key).inserted { out.append(spec) }
        }
        return out
    }

    /// Fallback candidate list when the interface can't report one.
    public static func defaultCandidates() -> [Candidate] {
        var out: [Candidate] = ChannelPlan.twentyMHzChannels(.ghz2_4).map { Candidate(band: .ghz2_4, primary: $0, width: .w20) }
        for w in [ChannelWidth.w20, .w40, .w80, .w160] {
            out += ChannelPlan.twentyMHzChannels(.ghz5).map { Candidate(band: .ghz5, primary: $0, width: w) }
            out += ChannelPlan.twentyMHzChannels(.ghz6).map { Candidate(band: .ghz6, primary: $0, width: w) }
        }
        // Without the card's own list, don't suggest UNII-4 (above channel 165): many APs and regions can't use it.
        return out.filter { $0.band != .ghz5 || ChannelPlan.spec(band: .ghz5, primary: $0.primary, width: $0.width).highMHz <= 5835 }
    }

    /// Scores averaged over several sweeps: mean noise rise (grade is from this), 90th-percentile peak,
    /// and the worst contention/utilization seen.
    public static func aggregate(_ specs: [ChannelSpec], over sweeps: [[Interferer]], noiseFloorDBm: Double) -> [ChannelScore] {
        guard !sweeps.isEmpty else {
            return specs.map { var s = score($0, against: [], noiseFloorDBm: noiseFloorDBm); s.samples = 0; return s }
        }
        return specs.map { spec in
            // Flags and floor are per spec; only the measurement varies by sweep.
            var s = score(spec, against: sweeps.last!, noiseFloorDBm: noiseFloorDBm)
            let floor = noiseFloor(noiseFloorDBm, for: spec)
            let each = sweeps.map { measure(spec, against: $0, floorDBm: floor) }
            let rises = each.map(\.noiseRiseDB).sorted()
            let mean = rises.reduce(0, +) / Double(rises.count)
            s.noiseRiseDB = mean
            s.peakNoiseRiseDB = rises[min(rises.count - 1, Int((Double(rises.count) * 0.9).rounded(.down)))]
            s.contenders = each.map(\.contenders).max() ?? 0
            s.overlapping = each.map(\.overlapping).max() ?? 0
            s.utilization = each.compactMap(\.utilization).max()
            let powers = each.compactMap(\.interferenceDBm).map { pow(10, $0 / 10) }
            s.interferenceDBm = powers.isEmpty ? nil : 10 * log10(powers.reduce(0, +) / Double(each.count))
            s.grade = Grade(noiseRiseDB: mean)
            s.samples = each.count
            return s
        }
    }

    /// Ranked scores per band and width, best first.
    public static func rank(_ specs: [ChannelSpec], against interferers: [Interferer], noiseFloorDBm: Double,
                            includeDFS: Bool) -> [Band: [ChannelWidth: [ChannelScore]]] {
        rank(specs.map { score($0, against: interferers, noiseFloorDBm: noiseFloorDBm) }, includeDFS: includeDFS)
    }

    public static func rank(_ scores: [ChannelScore], includeDFS: Bool) -> [Band: [ChannelWidth: [ChannelScore]]] {
        var out: [Band: [ChannelWidth: [ChannelScore]]] = [:]
        for s in scores {
            if s.isDFS && !includeDFS { continue }
            out[s.spec.band, default: [:]][s.spec.width, default: []].append(s)
        }
        for (band, byWidth) in out {
            for (w, list) in byWidth {
                out[band]![w] = list.sorted(by: better)
            }
        }
        return out
    }

    static func better(_ a: ChannelScore, _ b: ChannelScore) -> Bool {
        // Half-dB buckets: smaller differences are measurement noise, so fall through to the tie-breaks.
        let ra = (a.noiseRiseDB * 2).rounded(), rb = (b.noiseRiseDB * 2).rounded()
        if ra != rb { return ra < rb }
        let pa = ((a.peakNoiseRiseDB ?? a.noiseRiseDB) * 2).rounded(), pb = ((b.peakNoiseRiseDB ?? b.noiseRiseDB) * 2).rounded()
        if pa != pb { return pa < pb }
        if a.contenders != b.contenders { return a.contenders < b.contenders }
        if (a.utilization ?? 0) != (b.utilization ?? 0) { return (a.utilization ?? 0) < (b.utilization ?? 0) }
        // DFS has real costs (startup delay, radar evacuation), so only pick it when it's actually quieter.
        if a.isDFS != b.isDFS { return !a.isDFS }
        return a.spec.primary < b.spec.primary
    }
}
