import Testing
@testable import WhyFiCore

@Suite struct ChannelPlanTests {
    @Test func centerFrequencies() {
        #expect(ChannelPlan.centerMHz(band: .ghz2_4, channel: 1) == 2412)
        #expect(ChannelPlan.centerMHz(band: .ghz2_4, channel: 14) == 2484)
        #expect(ChannelPlan.centerMHz(band: .ghz5, channel: 36) == 5180)
        #expect(ChannelPlan.centerMHz(band: .ghz6, channel: 1) == 5955)
    }

    @Test func fiveGHzBlocks() {
        #expect(ChannelPlan.spec(band: .ghz5, primary: 44, width: .w80).segments == [5170...5250])
        #expect(ChannelPlan.spec(band: .ghz5, primary: 157, width: .w80).segments == [5735...5815])
        #expect(ChannelPlan.spec(band: .ghz5, primary: 64, width: .w160).segments == [5170...5330])
        #expect(ChannelPlan.spec(band: .ghz5, primary: 112, width: .w40).segments == [5530...5570])
    }

    @Test func sixGHzBlocks() {
        // 80 MHz channel 7 spans 1–13.
        #expect(ChannelPlan.spec(band: .ghz6, primary: 5, width: .w80).segments == [5945...6025])
        // 320 MHz channel 31 spans 1–61.
        #expect(ChannelPlan.spec(band: .ghz6, primary: 37, width: .w320).segments == [5945...6265])
    }

    @Test func twoFourFortyUsesSecondaryOffset() {
        #expect(ChannelPlan.spec(band: .ghz2_4, primary: 6, width: .w40, secondaryAbove: true).segments == [2427...2467])
        #expect(ChannelPlan.spec(band: .ghz2_4, primary: 6, width: .w40, secondaryAbove: false).segments == [2407...2447])
    }

    @Test func adjacentTwoFourChannelsPartiallyOverlap() {
        let one = ChannelPlan.spec(band: .ghz2_4, primary: 1, width: .w20)
        let three = ChannelPlan.spec(band: .ghz2_4, primary: 3, width: .w20)
        let six = ChannelPlan.spec(band: .ghz2_4, primary: 6, width: .w20)
        #expect(one.fraction(inside: three) == 0.5)
        #expect(one.fraction(inside: six) == 0)
    }

    @Test func dfsAndPSC() {
        #expect(ChannelPlan.isDFS(band: .ghz5, channel: 100))
        #expect(!ChannelPlan.isDFS(band: .ghz5, channel: 149))
        #expect(ChannelPlan.isPSC(band: .ghz6, channel: 37))
        #expect(!ChannelPlan.isPSC(band: .ghz6, channel: 33))
    }

    @Test func rangeLabels() {
        #expect(ChannelPlan.spec(band: .ghz5, primary: 149, width: .w80).rangeLabel == "149–161")
        #expect(ChannelPlan.spec(band: .ghz5, primary: 149, width: .w20).rangeLabel == "149")
        #expect(ChannelPlan.spec(band: .ghz2_4, primary: 11, width: .w20).rangeLabel == "11")
        #expect(ChannelPlan.spec(band: .ghz2_4, primary: 6, width: .w40, secondaryAbove: false).rangeLabel == "2+6")
    }
}

@Suite struct ReviewFixChannelTests {
    @Test func unii4Blocks() {
        #expect(ChannelPlan.spec(band: .ghz5, primary: 149, width: .w160).segments == [5735...5895])
        #expect(ChannelPlan.spec(band: .ghz5, primary: 165, width: .w40).segments == [5815...5855])
        #expect(ChannelPlan.spec(band: .ghz5, primary: 177, width: .w80).segments == [5815...5895])
        #expect(Band.ghz5.displayRange.contains(5895))
    }

    @Test func channel14() {
        #expect(ChannelPlan.spec(band: .ghz2_4, primary: 14, width: .w20).segments == [2474...2494])
    }
}
