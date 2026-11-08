import Foundation

/// Channel scores captured at one spot, so several spots can be compared.
public struct LocationSnapshot: Codable, Sendable, Identifiable, Hashable {
    public struct Network: Codable, Sendable, Hashable {
        public var bssid: String
        public var ssid: String?
        public var vendor: String?
        public var spec: ChannelSpec
        public var rssi: Int
        public var isOwn: Bool

        public init(bssid: String, ssid: String?, vendor: String?, spec: ChannelSpec, rssi: Int, isOwn: Bool) {
            self.bssid = bssid
            self.ssid = ssid
            self.vendor = vendor
            self.spec = spec
            self.rssi = rssi
            self.isOwn = isOwn
        }
    }

    public var id: UUID
    public var name: String
    public var date: Date
    /// Sweeps the scores average over.
    public var sweeps: Int
    public var scores: [ChannelScore]
    public var networks: [Network]

    public init(id: UUID = UUID(), name: String, date: Date, sweeps: Int, scores: [ChannelScore], networks: [Network]) {
        self.id = id
        self.name = name
        self.date = date
        self.sweeps = sweeps
        self.scores = scores
        self.networks = networks
    }
}

/// One candidate channel judged across several locations.
public struct CombinedScore: Sendable, Identifiable, Hashable {
    public var spec: ChannelSpec
    public var perLocation: [UUID: ChannelScore]
    public var worstNoiseRiseDB: Double
    public var meanNoiseRiseDB: Double
    public var isDFS: Bool

    public var id: ChannelSpec { spec }
    public var worstGrade: Grade { perLocation.values.map(\.grade).max() ?? .a }
}

public enum LocationComparison {
    /// Ranks channels by how they fare at the worst of the chosen locations, so the winner is good everywhere.
    public static func combine(_ snapshots: [LocationSnapshot], band: Band, width: ChannelWidth, includeDFS: Bool) -> [CombinedScore] {
        guard let first = snapshots.first else { return [] }
        let maps = snapshots.map { snap in
            (snap.id, Dictionary(snap.scores.filter { $0.spec.band == band && $0.spec.width == width }.map { ($0.spec, $0) },
                                 uniquingKeysWith: { a, _ in a }))
        }
        var out: [CombinedScore] = []
        for spec in maps[0].1.keys {
            var per: [UUID: ChannelScore] = [:]
            for (id, m) in maps {
                guard let s = m[spec] else { break }
                per[id] = s
            }
            guard per.count == snapshots.count, let any = per[first.id] else { continue }
            if any.isDFS && !includeDFS { continue }
            let rises = per.values.map(\.noiseRiseDB)
            out.append(CombinedScore(spec: spec, perLocation: per, worstNoiseRiseDB: rises.max()!,
                                     meanNoiseRiseDB: rises.reduce(0, +) / Double(rises.count), isDFS: any.isDFS))
        }
        return out.sorted { a, b in
            let wa = (a.worstNoiseRiseDB * 2).rounded(), wb = (b.worstNoiseRiseDB * 2).rounded()
            if wa != wb { return wa < wb }
            if a.meanNoiseRiseDB != b.meanNoiseRiseDB { return a.meanNoiseRiseDB < b.meanNoiseRiseDB }
            if a.isDFS != b.isDFS { return !a.isDFS }
            return a.spec.primary < b.spec.primary
        }
    }
}
