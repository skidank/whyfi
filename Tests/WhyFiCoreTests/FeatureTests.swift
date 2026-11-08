import Foundation
import Testing
@testable import WhyFiCore

@Suite struct RNRTests {
    /// One neighbour AP info: TBTT header (type 0, count 1, length 13), op class 133 (6 GHz 80), channel 37,
    /// then offset, BSSID, short SSID, BSS params (same SSID + co-located), PSD.
    static let rnr: [UInt8] = [0x00, 13, 133, 37, 0xff, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x78, 0x56, 0x34, 0x12, 0x42, 0x00]

    @Test func parsesEntry() {
        let ie = InformationElements(data: Data([201, UInt8(Self.rnr.count)] + Self.rnr))
        #expect(ie.reducedNeighbors == [.init(bssid: "02:11:22:33:44:55", operatingClass: 133, channel: 37,
                                              shortSSID: 0x1234_5678, sameSSID: true, coLocated: true)])
    }

    @Test func modelAddsReportedSixGHzNeighbour() {
        let ies = Data([201, UInt8(Self.rnr.count)] + Self.rnr)
        let reporter = ScanObservation(bssid: "00:11:22:33:44:55", ssid: "Home", rssi: -50, noise: 0, band: .ghz5,
                                       channel: 36, width: .w80, beaconInterval: 100, security: "WPA3",
                                       countryCode: nil, ieData: ies)
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [reporter]))
        let r = try! #require(m.reported["02:11:22:33:44:55"])
        #expect(r.isReported)
        #expect(r.isScorable)
        #expect(r.latest.ssid == "Home")
        #expect(r.latest.rssi == -50 - 4)  // 5 GHz reporter → 6 GHz: 11 − 7 dB
        #expect(r.spec.segments == [5945 + 160...6025 + 160])
        #expect(m.ownBSSIDs(connectedSSID: "Home", connectedBSSID: nil).contains("02:11:22:33:44:55"))

        // Once heard directly, the reported copy goes away.
        var heard = reporter
        heard.bssid = "02:11:22:33:44:55"
        heard.band = .ghz6
        heard.channel = 37
        heard.ieData = nil
        m.apply(Sweep(time: .now, observations: [reporter, heard]))
        #expect(m.reported["02:11:22:33:44:55"] == nil)
    }

    @Test func ignoresGarbage() {
        #expect(InformationElements.parseRNR([0x00, 13, 133]).isEmpty)
        #expect(InformationElements.parseRNR([0x00, 13, 133, 37, 1, 2]).isEmpty)
    }
}

@Suite struct VendorTests {
    let db = VendorDatabase(tsv: "001A2B\tUbiquiti\n00C0FF\tTP-Link\n00AABB\teero\n")

    @Test func exactMatch() {
        #expect(db.vendor(for: "00:1a:2b:3c:4d:5e") == Vendor(name: "Ubiquiti", inferred: false))
        #expect(db.vendor(for: "00:00:00:00:00:00") == nil)
    }

    @Test func locallyAdministeredClearsBit() {
        #expect(db.vendor(for: "02:1a:2b:1c:4d:5e") == Vendor(name: "Ubiquiti", inferred: true))
    }

    @Test func locallyAdministeredUsesSibling() {
        #expect(db.vendor(for: "06:c0:ff:61:a3:87") == nil)
        #expect(db.vendor(for: "06:c0:ff:61:a3:87", siblings: ["00:c0:ff:61:a3:86"])?.name == "TP-Link")
    }
}

@Suite struct AggregationTests {
    let spec = ChannelPlan.spec(band: .ghz5, primary: 36, width: .w20)

    func loud(_ on: Bool) -> [Interferer] {
        on ? [Interferer(id: "a", spec: spec, rssi: -55, utilization: 0.4)] : []
    }

    @Test func intermittentNeighbourAveragesAndPeaks() {
        let sweeps = (0..<10).map { loud($0 < 3) }
        let s = Scorer.aggregate([spec], over: sweeps, noiseFloorDBm: -95)[0]
        let full = Scorer.score(spec, against: loud(true), noiseFloorDBm: -95).noiseRiseDB
        #expect(abs(s.noiseRiseDB - full * 0.3) < 1e-6)
        #expect(s.peakNoiseRiseDB == full)
        #expect(s.contenders == 1)
        #expect(s.utilization == 0.4)
        #expect(s.samples == 10)
    }

    @Test func steadyBeatsSpikyAtEqualMean() {
        let quiet = ChannelPlan.spec(band: .ghz5, primary: 149, width: .w20)
        let a = Scorer.score(spec, against: [], noiseFloorDBm: -95)
        var b = Scorer.score(quiet, against: [], noiseFloorDBm: -95)
        b.peakNoiseRiseDB = 10
        #expect(Scorer.better(a, b))
    }
}

@Suite struct LocationComparisonTests {
    func snap(_ name: String, _ rises: [Int: Double]) -> LocationSnapshot {
        let scores = rises.map { ch, rise in
            var s = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: ch, width: .w80), against: [], noiseFloorDBm: -95)
            s.noiseRiseDB = rise
            s.grade = Grade(noiseRiseDB: rise)
            return s
        }
        return LocationSnapshot(name: name, date: .now, sweeps: 10, scores: scores, networks: [])
    }

    @Test func picksBestWorstCase() {
        // 36 is perfect in the office but awful in the bedroom; 149 is decent in both.
        let office = snap("Office", [36: 0, 149: 4, 100: 2])
        let bedroom = snap("Bedroom", [36: 20, 149: 5, 100: 9])
        let ranked = LocationComparison.combine([office, bedroom], band: .ghz5, width: .w80, includeDFS: true)
        #expect(ranked.map(\.spec.primary) == [149, 100, 36])
        #expect(ranked[0].worstNoiseRiseDB == 5)
        let noDFS = LocationComparison.combine([office, bedroom], band: .ghz5, width: .w80, includeDFS: false)
        #expect(noDFS.map(\.spec.primary) == [149, 36])
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let s = snap("Office", [36: 1])
        let back = try JSONDecoder().decode(LocationSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct ReportedEstimateTests {
    @Test func prefersSameDeviceSiblingOnSameBand() {
        // 2.4 GHz radio reports a co-located 5 GHz radio; the device's other 5 GHz BSS is heard at −86.
        let rnr: [UInt8] = [0x00, 13, 128, 149, 0xff, 0x00, 0x50, 0xc2, 0x00, 0xf2, 0x47, 0, 0, 0, 0, 0x40, 0]
        func obs(_ id: String, _ band: Band, _ ch: Int, _ rssi: Int, ies: Data? = nil) -> ScanObservation {
            ScanObservation(bssid: id, ssid: "X", rssi: rssi, noise: 0, band: band, channel: ch, width: .w20,
                            beaconInterval: 100, security: "WPA2", countryCode: nil, ieData: ies)
        }
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [
            obs("00:50:c2:00:f2:44", .ghz2_4, 6, -60, ies: Data([201, UInt8(rnr.count)] + rnr)),
            obs("00:50:c2:00:f2:45", .ghz5, 149, -86),
        ]))
        #expect(m.reported["00:50:c2:00:f2:47"]?.latest.rssi == -86)
    }
}
