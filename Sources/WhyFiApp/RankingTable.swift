import SwiftUI
import WhyFiCore

struct RankingTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("Width", selection: $model.width) {
                    ForEach(model.widthsForBand) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .layoutPriority(1)
                Spacer()
                Text("Ranked by noise rise: how much louder the noise floor gets from neighbours' signal falling inside the channel.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Table(model.currentRanking.enumerated().map { RankRow(rank: $0.offset + 1, element: $0.element) }, selection: $model.pinnedSpec) {
                TableColumn("#") { Text("\($0.rank)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(24)
                TableColumn("Channel") { e in
                    Text(e.element.spec.rangeLabel == "\(e.element.spec.primary)" ? "\(e.element.spec.primary)"
                         : "\(e.element.spec.primary)  (\(e.element.spec.rangeLabel))")
                }
                .width(min: 90, ideal: 120)
                TableColumn("Grade") { GradeBadge(grade: $0.element.grade, size: 18) }
                    .width(44)
                TableColumn(model.scoreWindow == .now ? "Noise rise" : "Avg rise") {
                    Text(String(format: "+%.1f dB", $0.element.noiseRiseDB)).monospacedDigit()
                }
                .width(70)
                TableColumn("Peak") { e in
                    Text(e.element.peakNoiseRiseDB.map { String(format: "+%.1f dB", $0) } ?? "—").monospacedDigit()
                }
                .width(64)
                TableColumn("Interference") { e in
                    Text(e.element.interferenceDBm.map { String(format: "%.0f dBm", $0) } ?? "none").monospacedDigit()
                }
                .width(80)
                TableColumn("Contending") { Text("\($0.element.contenders)").monospacedDigit() }
                    .width(70)
                TableColumn("Overlapping") { Text("\($0.element.overlapping)").monospacedDigit() }
                    .width(76)
                TableColumn("Busiest util") { e in
                    Text(e.element.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").monospacedDigit()
                }
                .width(76)
                TableColumn("Notes") { e in
                    Text([e.element.isDFS ? "DFS" : nil, e.element.isPSC ? "PSC" : nil].compactMap { $0 }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Peak = how bad it gets 10% of the time. Contending = neighbours at −82 dBm or louder, which make an AP on this channel wait its turn. Click a row to show it on the spectrum.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .onDisappear { model.pinnedSpec = nil }
    }
}

private struct RankRow: Identifiable {
    let rank: Int
    let element: ChannelScore
    var id: ChannelSpec { element.spec }
}
