import Foundation

public enum Band: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case ghz2_4 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case ghz6 = "6 GHz"

    public var id: String { rawValue }

    /// Frequency span drawn for this band, in MHz.
    public var displayRange: ClosedRange<Double> {
        switch self {
        case .ghz2_4: 2400...2484
        case .ghz5: 5165...5900
        case .ghz6: 5940...7130
        }
    }

    public static func < (a: Band, b: Band) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum ChannelWidth: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case w20 = 20, w40 = 40, w80 = 80, w160 = 160, w320 = 320

    public var id: Int { rawValue }
    public var mhz: Double { Double(rawValue) }
    public var label: String { "\(rawValue) MHz" }
    /// Number of 20 MHz subchannels.
    public var subchannels: Int { rawValue / 20 }

    public static func < (a: ChannelWidth, b: ChannelWidth) -> Bool { a.rawValue < b.rawValue }
}

/// The spectrum a BSS (or a candidate channel) occupies.
public struct ChannelSpec: Codable, Sendable, Hashable {
    public var band: Band
    public var primary: Int
    public var width: ChannelWidth
    /// Occupied frequency ranges in MHz; two entries for 80+80.
    public var segments: [ClosedRange<Double>]

    public init(band: Band, primary: Int, width: ChannelWidth, segments: [ClosedRange<Double>]) {
        self.band = band
        self.primary = primary
        self.width = width
        self.segments = segments
    }

    public var totalMHz: Double { segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    public var lowMHz: Double { segments.map(\.lowerBound).min() ?? 0 }
    public var highMHz: Double { segments.map(\.upperBound).max() ?? 0 }
    public var primaryCenterMHz: Double { ChannelPlan.centerMHz(band: band, channel: primary) }

    /// 20 MHz channel numbers covered, lowest to highest.
    public var coveredChannels: [Int] {
        ChannelPlan.twentyMHzChannels(band).filter { ch in
            let c = ChannelPlan.centerMHz(band: band, channel: ch)
            return segments.contains { $0.contains(c) }
        }
    }

    /// "149" for 20 MHz, "149–161" for wider blocks.
    public var rangeLabel: String {
        if width == .w20 && segments.count == 1 { return "\(primary)" }
        if band == .ghz2_4 {
            // 2.4 GHz channels are 5 MHz apart, so "covered" would list five of them; name primary + secondary.
            let secondary = primaryCenterMHz < (lowMHz + highMHz) / 2 ? primary + 4 : primary - 4
            return "\(min(primary, secondary))+\(max(primary, secondary))"
        }
        let chs = coveredChannels
        guard let lo = chs.first, let hi = chs.last, lo != hi else { return "\(primary)" }
        return segments.count > 1 ? "\(lo)–\(hi) (80+80)" : "\(lo)–\(hi)"
    }

    /// Fraction of this spec's bandwidth that falls inside `other`.
    public func fraction(inside other: ChannelSpec) -> Double {
        let total = totalMHz
        guard total > 0 else { return 0 }
        var overlap = 0.0
        for s in segments {
            for o in other.segments {
                overlap += max(0, min(s.upperBound, o.upperBound) - max(s.lowerBound, o.lowerBound))
            }
        }
        return overlap / total
    }
}

public enum ChannelPlan {
    public static func centerMHz(band: Band, channel: Int) -> Double {
        switch band {
        case .ghz2_4: channel == 14 ? 2484 : 2407 + 5 * Double(channel)
        case .ghz5: 5000 + 5 * Double(channel)
        case .ghz6: channel == 2 ? 5935 : 5950 + 5 * Double(channel)
        }
    }

    // Built once: these are hit for every candidate on every sweep.
    private static let channels2_4 = Array(1...13)
    /// Includes UNII-4 (169–177) so neighbours using it are drawn and scored; only channels the card
    /// reports as supported become candidates.
    private static let channels5 = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128,
                                    132, 136, 140, 144, 149, 153, 157, 161, 165, 169, 173, 177]
    private static let channels6 = Array(stride(from: 1, through: 233, by: 4))

    public static func twentyMHzChannels(_ band: Band) -> [Int] {
        switch band {
        case .ghz2_4: channels2_4
        case .ghz5: channels5
        case .ghz6: channels6
        }
    }

    /// 5 GHz UNII-2A / UNII-2C channels requiring radar detection.
    public static func isDFS(band: Band, channel: Int) -> Bool {
        band == .ghz5 && (52...144).contains(channel)
    }

    /// 6 GHz Preferred Scanning Channels (5, 21, 37, ...).
    public static func isPSC(band: Band, channel: Int) -> Bool {
        band == .ghz6 && channel >= 5 && (channel - 5) % 16 == 0
    }

    /// Spec for a block of `width` containing `primary`, using the fixed channelization.
    /// `secondaryAbove` only matters for 2.4 GHz 40 MHz.
    public static func spec(band: Band, primary: Int, width: ChannelWidth, secondaryAbove: Bool? = nil) -> ChannelSpec {
        let centerChannel: Double
        switch band {
        case .ghz2_4:
            if width == .w20 {
                centerChannel = Double(primary)
            } else {
                let above = secondaryAbove ?? (primary <= 7)
                centerChannel = Double(primary) + (above ? 2 : -2)
            }
            // 20 MHz goes through centerMHz so channel 14 (2484, off the 5 MHz grid) is right.
            let c = width == .w20 ? centerMHz(band: band, channel: primary) : centerMHz(band: band, channel: 0) + 5 * centerChannel
            let half = width == .w20 ? 10.0 : 20.0
            return ChannelSpec(band: band, primary: primary, width: width == .w20 ? .w20 : .w40,
                               segments: [(c - half)...(c + half)])
        case .ghz5:
            if let start = fiveGHzBlockStart(primary: primary, width: width) {
                centerChannel = Double(start + 2 * (width.subchannels - 1))
            } else {
                centerChannel = Double(primary)
            }
        case .ghz6:
            let span = 4 * width.subchannels
            let start = 1 + ((primary - 1) / span) * span
            centerChannel = Double(start + 2 * (width.subchannels - 1))
        }
        let c = 5 * centerChannel + (band == .ghz5 ? 5000 : 5950)
        return ChannelSpec(band: band, primary: primary, width: width,
                           segments: [(c - width.mhz / 2)...(c + width.mhz / 2)])
    }

    /// Global operating class (802.11 Annex E table E-4) to band and width.
    public static func operatingClass(_ c: Int) -> (band: Band, width: ChannelWidth)? {
        switch c {
        case 81, 82: (.ghz2_4, .w20)
        case 83, 84: (.ghz2_4, .w40)
        case 115, 118, 121, 124, 125: (.ghz5, .w20)
        case 116, 117, 119, 120, 122, 123, 126, 127: (.ghz5, .w40)
        case 128: (.ghz5, .w80)
        case 129, 130: (.ghz5, .w160)
        case 131, 136: (.ghz6, .w20)
        case 132: (.ghz6, .w40)
        case 133: (.ghz6, .w80)
        case 134, 135: (.ghz6, .w160)
        case 137: (.ghz6, .w320)
        default: nil
        }
    }

    /// Whether `primary` can anchor a `width` block in this band's channelization.
    public static func isValid(band: Band, primary: Int, width: ChannelWidth) -> Bool {
        guard twentyMHzChannels(band).contains(primary) else { return false }
        switch band {
        case .ghz2_4: return width <= .w40
        case .ghz5: return width == .w20 || fiveGHzBlockStart(primary: primary, width: width) != nil
        case .ghz6:
            let spec = spec(band: band, primary: primary, width: width)
            return spec.highMHz <= 7125
        }
    }

    private static func fiveGHzBlockStart(primary: Int, width: ChannelWidth) -> Int? {
        let starts: [Int]
        switch width {
        case .w20: return primary
        case .w40: starts = [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157, 165, 173]
        case .w80: starts = [36, 52, 100, 116, 132, 149, 165]
        case .w160: starts = [36, 100, 149]
        case .w320: return nil
        }
        let span = 4 * width.subchannels
        return starts.first { (primary >= $0) && (primary < $0 + span) }
    }

    /// Refines a CoreWLAN-reported channel with what the beacon's operation elements say.
    public static func spec(band: Band, primary: Int, reportedWidth: ChannelWidth, ies: InformationElements?) -> ChannelSpec {
        guard let ies else { return spec(band: band, primary: primary, width: reportedWidth) }

        // EHT is the only way to see 320 MHz (CoreWLAN tops out at 160).
        if let eht = ies.eht, eht.width == 4, band == .ghz6, eht.ccfs1 > 0 {
            let c = centerMHz(band: band, channel: eht.ccfs1)
            return ChannelSpec(band: band, primary: primary, width: .w320, segments: [(c - 160)...(c + 160)])
        }
        switch band {
        case .ghz2_4:
            let above: Bool? = switch ies.ht?.secondaryOffset {
            case .above: true
            case .below: false
            default: nil
            }
            return spec(band: band, primary: primary, width: reportedWidth, secondaryAbove: above)
        case .ghz5:
            // 80+80: VHT op width 1 with CCFS1 more than 16 channels from CCFS0, or legacy width 3.
            if let vht = ies.vht, vht.ccfs0 > 0, vht.ccfs1 > 0,
               (vht.width == 1 && abs(vht.ccfs1 - vht.ccfs0) > 16) || vht.width == 3 {
                let a = centerMHz(band: band, channel: vht.ccfs0), b = centerMHz(band: band, channel: vht.ccfs1)
                return ChannelSpec(band: band, primary: primary, width: .w160,
                                   segments: [(a - 40)...(a + 40), (b - 40)...(b + 40)].sorted { $0.lowerBound < $1.lowerBound })
            }
            return spec(band: band, primary: primary, width: reportedWidth)
        case .ghz6:
            if let he = ies.he6GHz {
                let w: ChannelWidth = [.w20, .w40, .w80, .w160][min(he.width, 3)]
                return spec(band: band, primary: primary, width: max(w, reportedWidth))
            }
            return spec(band: band, primary: primary, width: reportedWidth)
        }
    }
}
