import Foundation
import Testing
@testable import WhyFiCore

@Suite struct InformationElementsTests {
    static func tlv(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }

    @Test func parsesBasicElements() {
        let data = Data(Self.tlv(0, Array("Cafe".utf8)) + Self.tlv(3, [6]) + Self.tlv(7, Array("US ".utf8))
                        + Self.tlv(11, [12, 0, 128, 0, 0]) + Self.tlv(61, [6, 0x05] + Array(repeating: 0, count: 20)))
        let ie = InformationElements(data: data)
        #expect(ie.ssid == "Cafe")
        #expect(ie.dsChannel == 6)
        #expect(ie.countryCode == "US")
        #expect(ie.bssLoad?.stationCount == 12)
        #expect(abs((ie.bssLoad?.channelUtilization ?? 0) - 128.0 / 255) < 1e-9)
        #expect(ie.ht?.secondaryOffset == .above)
    }

    @Test func hiddenSSIDIsNil() {
        #expect(InformationElements(data: Data(Self.tlv(0, [0, 0, 0]))).ssid == nil)
    }

    @Test func parsesHE6GHzOperation() {
        // params with bit 17 set (6 GHz info present), color, MCS, then primary 37, width 3 (160), ccfs0 39, ccfs1 47.
        let body: [UInt8] = [36, 0x00, 0x00, 0x02, 0x01, 0xff, 0xff, 37, 0x03, 39, 47, 0]
        let ie = InformationElements(data: Data(Self.tlv(255, body)))
        #expect(ie.he6GHz == .init(primaryChannel: 37, width: 3, ccfs0: 39, ccfs1: 47))
        #expect(ChannelPlan.spec(band: .ghz6, primary: 37, reportedWidth: .w80, ies: ie).width == .w160)
    }

    @Test func ehtReveals320() {
        let body: [UInt8] = [106, 0x01, 0, 0, 0, 0, 0x04, 47, 31]
        var ie = InformationElements(data: Data(Self.tlv(255, body)))
        ie.hasEHTCapabilities = true
        let spec = ChannelPlan.spec(band: .ghz6, primary: 37, reportedWidth: .w160, ies: ie)
        #expect(spec.width == .w320)
        #expect(spec.segments == [5945...6265])
        #expect(ie.generation(band: .ghz6) == "Wi-Fi 7")
    }

    @Test func vht80Plus80() {
        let ie = InformationElements(data: Data(Self.tlv(192, [1, 42, 155, 0, 0])))
        let spec = ChannelPlan.spec(band: .ghz5, primary: 36, reportedWidth: .w160, ies: ie)
        #expect(spec.segments == [5170...5250, 5735...5815])
    }

    @Test func truncatedDataDoesNotCrash() {
        _ = InformationElements(data: Data([11, 5, 1]))
        _ = InformationElements(data: Data([255, 3, 36, 0]))
    }
}
