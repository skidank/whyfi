import Foundation

/// The subset of 802.11 beacon/probe-response information elements WhyFi uses.
public struct InformationElements: Codable, Sendable, Hashable {
    public struct BSSLoad: Codable, Sendable, Hashable {
        public var stationCount: Int
        /// Fraction of time the AP sensed the medium busy, 0...1.
        public var channelUtilization: Double
    }

    public enum SecondaryOffset: Int, Codable, Sendable { case none = 0, above = 1, below = 3 }

    public struct HTOperation: Codable, Sendable, Hashable {
        public var primaryChannel: Int
        public var secondaryOffset: SecondaryOffset
    }

    public struct VHTOperation: Codable, Sendable, Hashable {
        public var width: Int
        public var ccfs0: Int
        public var ccfs1: Int
    }

    public struct HE6GHzOperation: Codable, Sendable, Hashable {
        public var primaryChannel: Int
        /// 0 = 20, 1 = 40, 2 = 80, 3 = 160/80+80.
        public var width: Int
        public var ccfs0: Int
        public var ccfs1: Int
    }

    public struct EHTOperation: Codable, Sendable, Hashable {
        /// 0 = 20, 1 = 40, 2 = 80, 3 = 160, 4 = 320.
        public var width: Int
        public var ccfs0: Int
        public var ccfs1: Int
    }

    /// One BSS announced in a Reduced Neighbor Report (how 2.4/5 GHz APs advertise their 6 GHz radios).
    public struct ReportedNeighbor: Codable, Sendable, Hashable {
        public var bssid: String
        public var operatingClass: Int
        public var channel: Int
        public var shortSSID: UInt32?
        public var sameSSID: Bool
        public var coLocated: Bool
    }

    public var ssid: String?
    public var dsChannel: Int?
    public var reducedNeighbors: [ReportedNeighbor] = []
    public var countryCode: String?
    public var bssLoad: BSSLoad?
    public var ht: HTOperation?
    public var vht: VHTOperation?
    public var he6GHz: HE6GHzOperation?
    public var eht: EHTOperation?
    public var hasHTCapabilities = false
    public var hasVHTCapabilities = false
    public var hasHECapabilities = false
    public var hasEHTCapabilities = false
    public var hasRSN = false

    public init() {}

    public init(data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i + 2 <= bytes.count {
            let id = bytes[i], len = Int(bytes[i + 1])
            let start = i + 2, end = start + len
            guard end <= bytes.count else { break }
            parse(id: id, body: Array(bytes[start..<end]))
            i = end
        }
    }

    private mutating func parse(id: UInt8, body b: [UInt8]) {
        switch id {
        case 0:
            if !b.isEmpty, b.contains(where: { $0 != 0 }) { ssid = String(decoding: b, as: UTF8.self) }
        case 3 where b.count >= 1:
            dsChannel = Int(b[0])
        case 7 where b.count >= 2:
            countryCode = String(decoding: b[0..<2], as: UTF8.self)
        case 11 where b.count >= 3:
            bssLoad = BSSLoad(stationCount: Int(b[0]) | Int(b[1]) << 8,
                              channelUtilization: Double(b[2]) / 255)
        case 45:
            hasHTCapabilities = true
        case 48:
            hasRSN = true
        case 61 where b.count >= 2:
            ht = HTOperation(primaryChannel: Int(b[0]),
                             secondaryOffset: SecondaryOffset(rawValue: Int(b[1] & 0x3)) ?? .none)
        case 191:
            hasVHTCapabilities = true
        case 192 where b.count >= 3:
            vht = VHTOperation(width: Int(b[0]), ccfs0: Int(b[1]), ccfs1: Int(b[2]))
        case 201:
            reducedNeighbors += Self.parseRNR(b)
        case 255 where !b.isEmpty:
            parseExtension(id: b[0], body: Array(b.dropFirst()))
        default:
            break
        }
    }

    private mutating func parseExtension(id: UInt8, body b: [UInt8]) {
        switch id {
        case 35:
            hasHECapabilities = true
        case 36 where b.count >= 6:
            // HE Operation: params(3) BSS color(1) basic MCS(2) [VHT op info(3)] [co-hosted(1)] [6 GHz op info(5)]
            let params = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
            var off = 6
            if params & (1 << 14) != 0 { off += 3 }
            if params & (1 << 15) != 0 { off += 1 }
            if params & (1 << 17) != 0, b.count >= off + 4 {
                he6GHz = HE6GHzOperation(primaryChannel: Int(b[off]), width: Int(b[off + 1] & 0x3),
                                         ccfs0: Int(b[off + 2]), ccfs1: Int(b[off + 3]))
            }
        case 106 where b.count >= 1:
            // EHT Operation: params(1) basic MCS(4) [info: control(1) ccfs0(1) ccfs1(1) ...]
            if b[0] & 1 != 0, b.count >= 8 {
                eht = EHTOperation(width: Int(b[5] & 0x7), ccfs0: Int(b[6]), ccfs1: Int(b[7]))
            }
        case 108:
            hasEHTCapabilities = true
        default:
            break
        }
    }

    /// Reduced Neighbor Report: repeated [TBTT header(2) op class(1) channel(1) TBTT info × count].
    static func parseRNR(_ b: [UInt8]) -> [ReportedNeighbor] {
        var out: [ReportedNeighbor] = []
        var i = 0
        while i + 4 <= b.count {
            let header = Int(b[i]) | Int(b[i + 1]) << 8
            let fieldType = header & 0x3
            let count = ((header >> 4) & 0xF) + 1
            let length = (header >> 8) & 0xFF
            let opClass = Int(b[i + 2]), channel = Int(b[i + 3])
            i += 4
            for _ in 0..<count {
                guard length > 0, i + length <= b.count else { return out }
                let e = Array(b[i..<i + length])
                i += length
                // Layouts with a BSSID: 7, 8, 9, 11, 12, 13, 16+ bytes; the BSSID follows the 1-byte TBTT offset.
                guard fieldType == 0, length >= 7, length != 10 else { continue }
                let bssid = e[1...6].map { String(format: "%02x", $0) }.joined(separator: ":")
                var shortSSID: UInt32?
                var paramsAt: Int?
                if length >= 11 {
                    shortSSID = UInt32(e[7]) | UInt32(e[8]) << 8 | UInt32(e[9]) << 16 | UInt32(e[10]) << 24
                    if length >= 12 { paramsAt = 11 }
                } else if length >= 8 {
                    paramsAt = 7
                }
                let params = paramsAt.map { e[$0] } ?? 0
                out.append(ReportedNeighbor(bssid: bssid, operatingClass: opClass, channel: channel, shortSSID: shortSSID,
                                            sameSSID: params & 0x02 != 0, coLocated: params & 0x40 != 0))
            }
        }
        return out
    }

    /// Wi-Fi generation advertised by capability elements.
    public func generation(band: Band) -> String {
        if hasEHTCapabilities { return "Wi-Fi 7" }
        if hasHECapabilities { return band == .ghz6 ? "Wi-Fi 6E" : "Wi-Fi 6" }
        if hasVHTCapabilities { return "Wi-Fi 5" }
        if hasHTCapabilities { return "Wi-Fi 4" }
        return "Legacy"
    }
}
