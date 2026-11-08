import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WhyFiCore
import WhyFiScan

@MainActor @Observable
final class AppModel {
    let location = LocationGate()
    @ObservationIgnored private let scanner = WiFiScanner()

    private(set) var network = NetworkModel()
    private(set) var link: LinkStatus?
    private(set) var linkHistory: [RSSISample] = []
    private(set) var rankings: [Band: [ChannelWidth: [ChannelScore]]] = [:]
    /// Score of every 20 MHz channel, for the strip under the spectrum.
    private(set) var channelScores: [Band: [ChannelScore]] = [:]
    private(set) var ownBSSIDs: Set<String> = []
    private(set) var isScanning = false
    private(set) var lastError: String?
    /// All candidate scores for the current window (unfiltered by DFS), what a saved location captures.
    private(set) var windowScores: [ChannelScore] = []
    private(set) var vendors: [String: Vendor] = [:]
    /// Bands the Wi-Fi card can use; nil until the card has been asked.
    private(set) var supportedBands: Set<Band>?
    let locations = LocationStore()

    var isPaused = false { didSet { isPaused ? stop() : start() } }
    var scanInterval: Double = 20
    var includeDFS = true { didSet { rescore() } }
    var excludeOwn = true { didSet { rescore() } }
    var scoreWindow: ScoreWindow = .fifteenMinutes { didSet { rescore() } }
    var showStale = true
    var band: Band = .ghz5 { didSet { bandChosen = true } }
    var selectedWidth: [Band: ChannelWidth] = [.ghz2_4: .w20, .ghz5: .w80, .ghz6: .w160]
    var selectedBSSID: String?
    /// A channel the user picked from the ranking; overrides the best one in the spectrum highlight.
    var pinnedSpec: ChannelSpec?

    @ObservationIgnored private var candidates: [ChannelSpec] = []
    @ObservationIgnored private var recentSweeps: [Sweep] = []
    /// Raw per-sweep interferers (all BSSes, own included; filtered at scoring time).
    @ObservationIgnored private var interfererHistory: [(time: Date, interferers: [Interferer])] = []
    @ObservationIgnored private let vendorDB: VendorDatabase = {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "tsv"),
              let tsv = try? String(contentsOf: url, encoding: .utf8) else { return VendorDatabase(tsv: "") }
        return VendorDatabase(tsv: tsv)
    }()
    static let historyCapacity = 1080
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var bandChosen = false

    init() {
        Task { [weak self] in
            guard let self else { return }
            let supported = await scanner.supportedCandidates()
            candidates = Scorer.recommendable(supported.isEmpty ? Scorer.defaultCandidates() : supported)
            supportedBands = Set(candidates.map(\.band))
            rescore()
        }
        startLinkPolling()
    }

    // MARK: - Scanning

    func locationChanged() {
        if location.state == .authorized { start() } else { location.request() }
    }

    func start() {
        guard scanTask == nil, !isPaused, location.state == .authorized else { return }
        scanTask = Task { [weak self] in await self?.scanLoop() }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func scanLoop() async {
        defer { isScanning = false }
        while !Task.isCancelled {
            isScanning = true
            var wait = 2.0
            do {
                let result = try await scanner.scan()
                // Paused while the sweep was running: drop it so the scores the user froze stay put.
                guard !Task.isCancelled else { break }
                // Cached results are a growing union of everything seen recently, so they're only
                // good for a first paint.
                if result.isFresh || network.sweepCount == 0 {
                    apply(result.sweep)
                    wait = result.isFresh ? max(1, scanInterval - result.duration) : 2
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                wait = 5
            }
            isScanning = false
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func apply(_ sweep: Sweep) {
        network.apply(sweep)
        recentSweeps.append(sweep)
        if recentSweeps.count > 90 { recentSweeps.removeFirst() }
        interfererHistory.append((sweep.time, interferers(smoothed: false, excluding: [])))
        if interfererHistory.count > Self.historyCapacity { interfererHistory.removeFirst() }
        updateVendors()
        rescore()
    }

    private func updateVendors() {
        let ids = Array(network.records.keys)
        for id in ids where vendors[id] == nil {
            if let v = vendorDB.vendor(for: id, siblings: ids) { vendors[id] = v }
        }
        for r in network.reported.values where vendors[r.id] == nil {
            if let v = vendorDB.vendor(for: r.id, siblings: ids + [r.reportedBy].compactMap { $0 }) { vendors[r.id] = v }
        }
    }

    private func startLinkPolling() {
        linkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let l = await self.scanner.link() { self.updateLink(l) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func updateLink(_ l: LinkStatus) {
        let changed = l.bssid != link?.bssid
        link = l
        if l.isAssociated {
            linkHistory.append(RSSISample(time: l.time, rssi: l.rssi))
            if linkHistory.count > 1800 { linkHistory.removeFirst() }
        }
        if !bandChosen, let b = l.band { band = b }
        if changed { rescore() }
    }

    // MARK: - Scoring

    /// Per-20 MHz noise floor: the link's measured noise, normalized from the link's width.
    var noiseFloor: Double {
        guard let l = link, l.noise != 0 else { return Scorer.defaultNoiseFloorDBm }
        return Double(l.noise) - 10 * log10(Double(l.width?.rawValue ?? 20) / 20)
    }

    private func interferers(smoothed: Bool, excluding own: Set<String>) -> [Interferer] {
        (network.active + network.activeReported)
            .filter { $0.isScorable && !own.contains($0.id) }
            .map { Interferer(id: $0.id, spec: $0.spec, rssi: $0.rssi(smoothed: smoothed),
                              utilization: $0.ies?.bssLoad?.channelUtilization) }
    }

    private static let stripSpecs: [ChannelSpec] = Band.allCases.flatMap { b in
        ChannelPlan.twentyMHzChannels(b).map { ChannelPlan.spec(band: b, primary: $0, width: .w20) }
    }

    func rescore() {
        ownBSSIDs = network.ownBSSIDs(connectedSSID: link?.ssid, connectedBSSID: link?.bssid)
        let excluded = excludeOwn ? ownBSSIDs : []
        let all = candidates + Self.stripSpecs
        let scores: [ChannelScore]
        switch scoreWindow {
        case .now:
            let live = interferers(smoothed: true, excluding: excluded)
            scores = all.map { Scorer.score($0, against: live, noiseFloorDBm: noiseFloor) }
        default:
            let cutoff = scoreWindow.seconds.map { (network.lastSweep ?? .now).addingTimeInterval(-$0) } ?? .distantPast
            let sweeps = interfererHistory.filter { $0.time >= cutoff }.map { $0.interferers.filter { !excluded.contains($0.id) } }
            scores = Scorer.aggregate(all, over: sweeps, noiseFloorDBm: noiseFloor)
        }
        windowScores = Array(scores.prefix(candidates.count))
        rankings = Scorer.rank(windowScores, includeDFS: includeDFS)
        channelScores = Dictionary(grouping: scores.dropFirst(candidates.count), by: \.spec.band)
    }

    var windowSampleCount: Int { network.sweepCount == 0 ? 0 : windowScores.first?.samples ?? 0 }
    var canSaveLocation: Bool { network.sweepCount > 0 && !windowScores.isEmpty }

    // MARK: - Locations

    func saveLocation(named name: String) {
        let nets = (network.active + network.activeReported).map {
            LocationSnapshot.Network(bssid: $0.id, ssid: $0.latest.ssid, vendor: vendors[$0.id]?.label, spec: $0.spec,
                                     rssi: Int($0.smoothedRSSI.rounded()), isOwn: ownBSSIDs.contains($0.id))
        }
        locations.add(LocationSnapshot(name: name, date: .now, sweeps: windowSampleCount, scores: windowScores, networks: nets))
    }

    // MARK: - Derived

    /// The chosen width for this band, falling back to the widest available one not above it when the card
    /// doesn't offer it (e.g. no 160 MHz on 6 GHz).
    var width: ChannelWidth {
        get {
            let want = selectedWidth[band] ?? .w20
            let have = widthsForBand
            if have.isEmpty || have.contains(want) { return want }
            return have.last(where: { $0 < want }) ?? have[0]
        }
        set { selectedWidth[band] = newValue; pinnedSpec = nil }
    }

    var widthsForBand: [ChannelWidth] {
        (rankings[band] ?? [:]).keys.sorted()
    }

    var currentRanking: [ChannelScore] { rankings[band]?[width] ?? [] }

    var highlightedSpec: ChannelSpec? {
        if let p = pinnedSpec, p.band == band { return p }
        return currentRanking.first?.spec
    }

    var records: [BSSRecord] {
        (Array(network.records.values) + network.reported.values).filter { showStale || !$0.isStale }
    }

    var selectedRecord: BSSRecord? { selectedBSSID.flatMap { network.records[$0] ?? network.reported[$0] } }

    func isOwn(_ r: BSSRecord) -> Bool { ownBSSIDs.contains(r.id) }

    var hasLocationAccess: Bool { location.state == .authorized }

    // MARK: - Export

    func exportScans() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "whyfi-scan-\(Int(Date().timeIntervalSince1970)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try enc.encode(recentSweeps).write(to: url)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }
}

enum ScoreWindow: String, CaseIterable, Identifiable {
    case now = "Now"
    case fiveMinutes = "5 min"
    case fifteenMinutes = "15 min"
    case hour = "1 hour"
    case session = "Whole session"

    var id: String { rawValue }

    /// nil for `now` (live smoothed values) and `session` (everything recorded).
    var seconds: TimeInterval? {
        switch self {
        case .now, .session: nil
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .hour: 3600
        }
    }
}
