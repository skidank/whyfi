import Foundation
import Testing
@testable import WhyFiCore

@Suite struct ScoringTests {
    func interferer(_ band: Band, _ ch: Int, _ w: ChannelWidth = .w20, rssi: Double) -> Interferer {
        Interferer(spec: ChannelPlan.spec(band: band, primary: ch, width: w), rssi: rssi, utilization: nil)
    }

    @Test func emptyChannelScoresA() {
        let s = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: 149, width: .w20),
                             against: [interferer(.ghz5, 36, rssi: -40)], noiseFloorDBm: -95)
        #expect(s.noiseRiseDB == 0)
        #expect(s.grade == .a)
        #expect(s.overlapping == 0)
    }

    @Test func coChannelLoudNeighbourIsBad() {
        let s = Scorer.score(ChannelPlan.spec(band: .ghz2_4, primary: 6, width: .w20),
                             against: [interferer(.ghz2_4, 6, rssi: -50)], noiseFloorDBm: -95)
        #expect(s.noiseRiseDB > 40)
        #expect(s.contenders == 1)
        #expect(s.grade == .f)
    }

    @Test func wideNeighbourCountsOnlyItsOverlapFraction() {
        // An 80 MHz neighbour puts a quarter of its power into one 20 MHz channel: −6 dB.
        let wide = interferer(.ghz5, 36, .w80, rssi: -60)
        let s = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: 40, width: .w20), against: [wide], noiseFloorDBm: -95)
        #expect(abs(s.interferenceDBm! - (-60 - 10 * log10(4.0))) < 0.01)
    }

    @Test func rankingPrefersQuietChannelAndRespectsDFSToggle() {
        let specs = Scorer.recommendable(Scorer.defaultCandidates())
        let interferers = [interferer(.ghz5, 36, .w80, rssi: -50), interferer(.ghz5, 149, .w80, rssi: -60)]
        let withDFS = Scorer.rank(specs, against: interferers, noiseFloorDBm: -95, includeDFS: true)
        #expect(withDFS[.ghz5]![.w80]!.first!.isDFS)
        let noDFS = Scorer.rank(specs, against: interferers, noiseFloorDBm: -95, includeDFS: false)
        #expect(noDFS[.ghz5]![.w80]!.map(\.spec.primary) == [149, 36])
    }

    @Test func recommendableFiltersAndDedupes() {
        let specs = Scorer.recommendable(Scorer.defaultCandidates())
        #expect(specs.filter { $0.band == .ghz2_4 }.map(\.primary) == [1, 6, 11])
        #expect(specs.filter { $0.band == .ghz5 && $0.width == .w160 }.count == 2)
        #expect(specs.filter { $0.band == .ghz6 }.allSatisfy { ChannelPlan.isPSC(band: .ghz6, channel: $0.primary) })
    }
}

@Suite struct NetworkModelTests {
    func obs(_ bssid: String, ssid: String?, rssi: Int = -60) -> ScanObservation {
        ScanObservation(bssid: bssid, ssid: ssid, rssi: rssi, noise: 0, band: .ghz5, channel: 36, width: .w80,
                    beaconInterval: 100, security: "WPA2", countryCode: nil, ieData: nil)
    }

    @Test func staleThenDropped() {
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [obs("aa:bb:cc:dd:ee:01", ssid: "A")]))
        for _ in 0..<BSSRecord.staleAfterMissed { m.apply(Sweep(time: .now, observations: [])) }
        #expect(m.records.count == 1)
        #expect(m.active.isEmpty)
        for _ in BSSRecord.staleAfterMissed..<BSSRecord.dropAfterMissed { m.apply(Sweep(time: .now, observations: [])) }
        #expect(m.records.isEmpty)
    }

    @Test func smoothingAndHistory() {
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [obs("aa:bb:cc:dd:ee:01", ssid: "A", rssi: -60)]))
        m.apply(Sweep(time: .now, observations: [obs("aa:bb:cc:dd:ee:01", ssid: "A", rssi: -40)]))
        let r = m.records["aa:bb:cc:dd:ee:01"]!
        #expect(abs(r.smoothedRSSI - (-54)) < 1e-9)
        #expect(r.history.count == 2)
    }

    @Test func ownNetworkIncludesSiblingRadios() {
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [
            obs("00:1a:2b:3c:4d:5e", ssid: "Home"),
            obs("02:1a:2b:1c:4d:5e", ssid: "HomeGuest"),
            obs("00:1a:2b:3c:4d:5d", ssid: nil),
            obs("06:77:88:99:aa:bb", ssid: "Home"),
            obs("00:aa:bb:cc:dd:01", ssid: "Neighbour"),
        ]))
        let own = m.ownBSSIDs(connectedSSID: "Home", connectedBSSID: "00:1a:2b:3c:4d:5e")
        #expect(own == ["00:1a:2b:3c:4d:5e", "02:1a:2b:1c:4d:5e", "00:1a:2b:3c:4d:5d", "06:77:88:99:aa:bb"])
    }
}

@Suite struct OwnNetworkReviewTests {
    func obs(_ bssid: String, _ ssid: String?) -> ScanObservation {
        ScanObservation(bssid: bssid, ssid: ssid, rssi: -60, noise: 0, band: .ghz5, channel: 36, width: .w80,
                        beaconInterval: 100, security: "WPA2", countryCode: nil, ieData: nil)
    }

    @Test func adjacentSerialNeighboursAreNotOwn() {
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [
            obs("00:1a:2b:3c:4d:5e", "Home"),
            obs("00:1a:2b:3c:4d:5f", "NextDoor"),
            obs("00:1a:2b:3c:99:5e", "Downstairs"),
            obs("00:1a:2b:3c:4d:60", "home-5G"),
        ]))
        let own = m.ownBSSIDs(connectedSSID: "Home", connectedBSSID: "00:1a:2b:3c:4d:5e")
        #expect(own == ["00:1a:2b:3c:4d:5e", "00:1a:2b:3c:4d:60"])
    }

    @Test func reporterChoiceIsDeterministic() {
        // Own AP (strong, co-located flag) and a neighbour both report the same 6 GHz BSSID.
        func rnr(coLocated: Bool) -> Data {
            let e: [UInt8] = [0x00, 13, 133, 37, 0xff, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0, 0, 0, 0, coLocated ? 0x42 : 0x00, 0]
            return Data([201, UInt8(e.count)] + e)
        }
        for _ in 0..<20 {
            var m = NetworkModel()
            var mine = obs("00:11:22:33:44:55", "Home"); mine.rssi = -50; mine.ieData = rnr(coLocated: true)
            var theirs = obs("00:99:88:77:66:55", "Other"); theirs.rssi = -40; theirs.ieData = rnr(coLocated: false)
            m.apply(Sweep(time: .now, observations: [theirs, mine]))
            #expect(m.reported["02:11:22:33:44:55"]?.reportedBy == "00:11:22:33:44:55")
        }
    }

    @Test func duplicateBSSIDInSweepRecordsOnce() {
        var m = NetworkModel()
        var weak = obs("00:aa:bb:cc:dd:01", "A"); weak.rssi = -80
        var strong = weak; strong.rssi = -50
        m.apply(Sweep(time: .now, observations: [weak, strong]))
        #expect(m.records["00:aa:bb:cc:dd:01"]?.history.count == 1)
        #expect(m.records["00:aa:bb:cc:dd:01"]?.latest.rssi == -50)
    }
}

@Suite struct ScoringReviewTests {
    @Test func widerChannelHasHigherFloor() {
        let n = Interferer(spec: ChannelPlan.spec(band: .ghz5, primary: 36, width: .w20), rssi: -70, utilization: nil)
        let narrow = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: 36, width: .w20), against: [n], noiseFloorDBm: -95)
        let wide = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: 36, width: .w160), against: [n], noiseFloorDBm: -95)
        #expect(abs(narrow.noiseRiseDB - wide.noiseRiseDB - 10 * log10(8.0)) < 0.2)
    }

    @Test func emptyAggregateHasZeroSamples() {
        let s = Scorer.aggregate([ChannelPlan.spec(band: .ghz5, primary: 36, width: .w20)], over: [], noiseFloorDBm: -95)
        #expect(s[0].samples == 0)
    }

    @Test func decodesScoreSavedBeforeNewerFields() throws {
        let s = Scorer.score(ChannelPlan.spec(band: .ghz5, primary: 36, width: .w20), against: [], noiseFloorDBm: -95)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["samples"] = nil
        json["peakNoiseRiseDB"] = nil
        let back = try JSONDecoder().decode(ChannelScore.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.samples == 1)
        #expect(back.spec == s.spec)
    }
}

@Suite struct GuestAnchorTests {
    @Test func connectedToGuestStillFindsMainRadios() {
        func obs(_ id: String, _ ssid: String?) -> ScanObservation {
            ScanObservation(bssid: id, ssid: ssid, rssi: -50, noise: 0, band: .ghz5, channel: 36, width: .w80,
                            beaconInterval: 100, security: "WPA2", countryCode: nil, ieData: nil)
        }
        var m = NetworkModel()
        m.apply(Sweep(time: .now, observations: [
            obs("02:1a:2b:1c:4d:5e", "Home Guest"),
            obs("00:1a:2b:3c:4d:5e", "Home"),
            obs("00:1a:2b:3c:4d:5f", "Home-5G"),
            obs("00:1a:2b:3c:4d:60", "NextDoor"),
        ]))
        let own = m.ownBSSIDs(connectedSSID: "Home Guest", connectedBSSID: "02:1a:2b:1c:4d:5e")
        #expect(own == ["02:1a:2b:1c:4d:5e", "00:1a:2b:3c:4d:5e", "00:1a:2b:3c:4d:5f"])
    }
}
