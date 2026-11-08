import Foundation

/// One BSS as seen in one scan. Plain value copy of a CWNetwork.
public struct ScanObservation: Codable, Sendable, Hashable {
    public var bssid: String
    public var ssid: String?
    public var rssi: Int
    /// CoreWLAN only reports noise for the associated network; 0 otherwise.
    public var noise: Int
    public var band: Band
    public var channel: Int
    public var width: ChannelWidth
    public var beaconInterval: Int
    public var security: String
    public var countryCode: String?
    public var ieData: Data?

    public init(bssid: String, ssid: String?, rssi: Int, noise: Int, band: Band, channel: Int,
                width: ChannelWidth, beaconInterval: Int, security: String, countryCode: String?, ieData: Data?) {
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.noise = noise
        self.band = band
        self.channel = channel
        self.width = width
        self.beaconInterval = beaconInterval
        self.security = security
        self.countryCode = countryCode
        self.ieData = ieData
    }
}

public struct Sweep: Codable, Sendable {
    public var time: Date
    public var observations: [ScanObservation]

    public init(time: Date, observations: [ScanObservation]) {
        self.time = time
        self.observations = observations
    }
}

public struct RSSISample: Sendable, Hashable, Identifiable {
    public var time: Date
    public var rssi: Int
    public var id: Date { time }

    public init(time: Date, rssi: Int) {
        self.time = time
        self.rssi = rssi
    }
}

/// Everything known about one BSSID across sweeps.
public struct BSSRecord: Sendable, Identifiable {
    public var id: String { latest.bssid }
    public var latest: ScanObservation
    public var ies: InformationElements?
    public var spec: ChannelSpec
    public var firstSeen: Date
    public var lastSeen: Date
    public var sweepsMissed = 0
    public var smoothedRSSI: Double
    public var history: [RSSISample]
    /// Not heard directly: announced in another AP's Reduced Neighbor Report. Signal is estimated.
    public var isReported = false
    public var reportedBy: String?
    /// The reporter says this radio is in the same device, so its signal can be estimated from the reporter's.
    /// Other reported BSSes (e.g. remote mesh nodes) have unknown signal and are not scored.
    public var reportedCoLocated = false

    /// Whether this BSS should count as interference.
    public var isScorable: Bool { !isReported || reportedCoLocated }

    public static let staleAfterMissed = 3
    public static let dropAfterMissed = 10
    public static let historyCapacity = 360
    static let smoothing = 0.3

    init(_ o: ScanObservation, at time: Date) {
        latest = o
        ies = o.ieData.map(InformationElements.init(data:))
        spec = ChannelPlan.spec(band: o.band, primary: o.channel, reportedWidth: o.width, ies: ies)
        firstSeen = time
        lastSeen = time
        smoothedRSSI = Double(o.rssi)
        history = [RSSISample(time: time, rssi: o.rssi)]
    }

    mutating func update(_ o: ScanObservation, at time: Date) {
        if o.ieData != latest.ieData || o.channel != latest.channel || o.width != latest.width {
            ies = o.ieData.map(InformationElements.init(data:))
            spec = ChannelPlan.spec(band: o.band, primary: o.channel, reportedWidth: o.width, ies: ies)
        }
        latest = o
        lastSeen = time
        sweepsMissed = 0
        smoothedRSSI += Self.smoothing * (Double(o.rssi) - smoothedRSSI)
        history.append(RSSISample(time: time, rssi: o.rssi))
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }

    public var isStale: Bool { sweepsMissed >= Self.staleAfterMissed }
    /// Signal used for scoring: smoothed, or the raw last value for a single-sweep snapshot.
    public func rssi(smoothed: Bool) -> Double { smoothed ? smoothedRSSI : Double(latest.rssi) }
    public var displaySSID: String { latest.ssid ?? ies?.ssid ?? "(hidden)" }
    public var isHidden: Bool { latest.ssid == nil && ies?.ssid == nil }
    public var generation: String { ies?.generation(band: latest.band) ?? "—" }
}

/// All BSSes seen so far, with staleness tracking. Pure value type so it can be tested.
public struct NetworkModel: Sendable {
    public private(set) var records: [String: BSSRecord] = [:]
    /// BSSes known only from neighbour reports, keyed by BSSID; never also present in `records`.
    public private(set) var reported: [String: BSSRecord] = [:]
    /// Typical extra loss relative to 2.4 GHz for the same device and distance (free-space path loss,
    /// plus lower indoor power limits on 6 GHz). Used to estimate a reported radio's signal.
    static func bandLossDB(_ b: Band) -> Int {
        switch b {
        case .ghz2_4: 0
        case .ghz5: 7
        case .ghz6: 11
        }
    }

    /// Best guess at a reported radio's signal: a directly heard radio on the same band from the same device
    /// (BSSID equal in the first five octets) if there is one, else the reporter adjusted for band.
    func estimatedRSSI(for bssid: String, band: Band, reporter: BSSRecord) -> Int {
        let prefix = bssid.prefix(14)
        if let sibling = records.values.first(where: { $0.latest.band == band && !$0.isStale && $0.id.prefix(14) == prefix }) {
            return sibling.latest.rssi
        }
        return reporter.latest.rssi - (Self.bandLossDB(band) - Self.bandLossDB(reporter.latest.band))
    }

    public private(set) var sweepCount = 0
    public private(set) var lastSweep: Date?

    public init() {}

    public mutating func apply(_ sweep: Sweep) {
        sweepCount += 1
        lastSweep = sweep.time
        // Some firmware reports the same BSSID twice per sweep; keep only the strongest copy.
        var strongest: [String: ScanObservation] = [:]
        for o in sweep.observations where o.rssi > strongest[o.bssid]?.rssi ?? .min { strongest[o.bssid] = o }
        let seen = Set(strongest.keys)
        for o in strongest.values {
            if records[o.bssid] != nil {
                records[o.bssid]!.update(o, at: sweep.time)
            } else {
                records[o.bssid] = BSSRecord(o, at: sweep.time)
            }
        }
        for key in records.keys where !seen.contains(key) {
            records[key]!.sweepsMissed += 1
            if records[key]!.sweepsMissed >= BSSRecord.dropAfterMissed { records[key] = nil }
        }
        applyNeighborReports(heard: seen, at: sweep.time)
    }

    private mutating func applyNeighborReports(heard: Set<String>, at time: Date) {
        // Several APs can report the same BSSID. Pick one reporter deterministically: one that says the radio
        // is co-located (its signal tells us about the radio's), then the strongest, then the lowest BSSID.
        var best: [String: (reporter: BSSRecord, entry: InformationElements.ReportedNeighbor)] = [:]
        for id in heard.sorted() {
            guard let reporter = records[id], let entries = reporter.ies?.reducedNeighbors else { continue }
            for e in entries where records[e.bssid] == nil {
                if let cur = best[e.bssid] {
                    let curKey = (cur.entry.coLocated ? 1 : 0, cur.reporter.latest.rssi)
                    let newKey = (e.coLocated ? 1 : 0, reporter.latest.rssi)
                    guard newKey > curKey else { continue }
                }
                best[e.bssid] = (reporter, e)
            }
        }
        var refreshed = Set<String>()
        for (bssid, (reporter, e)) in best {
            guard let (band, width) = ChannelPlan.operatingClass(e.operatingClass),
                  ChannelPlan.twentyMHzChannels(band).contains(e.channel) else { continue }
            let obs = ScanObservation(bssid: e.bssid, ssid: e.sameSSID ? reporter.latest.ssid : nil,
                                      rssi: estimatedRSSI(for: e.bssid, band: band, reporter: reporter), noise: 0, band: band,
                                      channel: e.channel, width: width, beaconInterval: 0, security: "—",
                                      countryCode: nil, ieData: nil)
            if reported[e.bssid] != nil {
                reported[e.bssid]!.update(obs, at: time)
            } else {
                var r = BSSRecord(obs, at: time)
                r.isReported = true
                reported[e.bssid] = r
            }
            reported[e.bssid]!.reportedBy = reporter.id
            reported[e.bssid]!.reportedCoLocated = e.coLocated
            refreshed.insert(bssid)
        }
        for key in reported.keys where !refreshed.contains(key) {
            if records[key] != nil {
                reported[key] = nil
                continue
            }
            reported[key]!.sweepsMissed += 1
            if reported[key]!.sweepsMissed >= BSSRecord.dropAfterMissed { reported[key] = nil }
        }
    }

    public var active: [BSSRecord] { records.values.filter { !$0.isStale } }
    public var activeReported: [BSSRecord] { reported.values.filter { !$0.isStale } }

    /// BSSIDs belonging to the user's own network: the connected BSSID and anything with the same SSID
    /// (anchors), plus BSSIDs the same AP derives for guest SSIDs and other radios:
    /// - locally administered, same first octet once the LA bit is cleared, at most one other octet different
    ///   (neighbours' burned-in BSSIDs are globally administered, so this can't catch them);
    /// - globally administered, first five octets equal, last octet within ±8, and hidden or an SSID related to
    ///   the matched anchor's ("Home" / "Home-5G" / "Home Guest"), so an adjacent-serial neighbour isn't swallowed.
    public func ownBSSIDs(connectedSSID: String?, connectedBSSID: String?) -> Set<String> {
        var own = Set<String>()
        if let b = connectedBSSID { own.insert(b.lowercased()) }
        if let s = connectedSSID {
            for r in records.values where r.latest.ssid == s { own.insert(r.id.lowercased()) }
        }
        // Two passes: when connected to a guest (LA) BSSID, the first finds the AP's burned-in BSSID and the
        // second finds that radio's siblings. Bounded on purpose; no fixpoint.
        for _ in 0..<2 {
            let anchors = own.compactMap { id in
                Self.octets(id).map { ($0, records[id]?.latest.ssid ?? connectedSSID) }
            }
            for r in records.values where !own.contains(r.id) {
                guard let o = Self.octets(r.id) else { continue }
                if anchors.contains(where: { Self.isDerived(o, from: $0.0, ssid: r.latest.ssid, anchorSSID: $0.1) }) {
                    own.insert(r.id)
                }
            }
        }
        for r in reported.values where r.reportedBy.map(own.contains) == true { own.insert(r.id) }
        return own
    }

    /// Whether BSSID `o` looks derived from anchor `a`; `anchorSSID` is the anchor's own SSID.
    static func isDerived(_ o: [UInt8], from a: [UInt8], ssid: String?, anchorSSID: String?) -> Bool {
        let rest = zip(a.dropFirst(), o.dropFirst()).filter { $0 != $1 }.count
        if o[0] & 0x02 != 0 || a[0] & 0x02 != 0 {
            // Either side derived: only the LA bit and the upper nibble of the first octet may differ.
            return (o[0] ^ a[0]) & 0x0D == 0 && rest <= 1
        }
        guard o[0] == a[0], a[1...4] == o[1...4], abs(Int(a[5]) - Int(o[5])) <= 8 else { return false }
        guard let ssid else { return true }
        guard let own = anchorSSID?.trimmingCharacters(in: .whitespaces).lowercased(), !own.isEmpty else { return false }
        let mine = ssid.trimmingCharacters(in: .whitespaces).lowercased()
        return mine.hasPrefix(own) || own.hasPrefix(mine)
    }

    private static func octets(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }
}
