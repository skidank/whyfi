import SwiftUI
import WhyFiCore

struct RecommendationStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Best \(model.band.rawValue) channel")
                    .font(.headline)
                if model.excludeOwn, !model.ownBSSIDs.isEmpty {
                    Text("· ignoring your network (\(model.ownBSSIDs.count) radios)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Score over", selection: $model.scoreWindow) {
                    ForEach(ScoreWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("Average scores over recent sweeps so neighbours that come and go are counted fairly")
                if model.scoreWindow != .now {
                    Text("\(model.windowSampleCount) sweep\(model.windowSampleCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                ForEach(model.widthsForBand) { w in
                    if let best = model.rankings[model.band]?[w]?.first {
                        WidthChip(width: w, score: best, selected: model.width == w) { model.width = w }
                    }
                }
                if model.widthsForBand.isEmpty {
                    Text(model.supportedBands.map { $0.contains(model.band) } == false
                         ? "Your Wi-Fi card doesn't support this band." : "Waiting for scan results…")
                        .foregroundStyle(.secondary)
                }
            } }
            Text(advice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advice: String {
        let general = "Scores reflect what this Mac hears. Scan from where the AP sits, or where you use Wi-Fi most."
        switch model.band {
        case .ghz2_4:
            return "Only 1, 6 and 11 are suggested: every other channel partly overlaps two of them. Use 20 MHz on 2.4 GHz; 40 MHz collides with almost everyone. " + general
        case .ghz5:
            return general
        case .ghz6:
            return "Only Preferred Scanning Channels (5, 21, 37, …) are suggested; clients find them fastest. Needs Wi-Fi 6E or newer on both AP and clients. " + general
        }
    }
}

struct WidthChip: View {
    let width: ChannelWidth
    let score: ChannelScore
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GradeBadge(grade: score.grade)
                VStack(alignment: .leading, spacing: 1) {
                    Text(width.label).font(.caption).foregroundStyle(.secondary)
                    Text("ch \(score.spec.primary)").font(.title3.weight(.semibold))
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help("Channels \(score.spec.rangeLabel) at \(width.label). Click to show on the spectrum and in the ranking."
              + (score.isDFS ? " DFS: the AP must check for radar for 1 minute (10 on 120–128) before using it, and move off if radar appears." : ""))
    }

    private var detail: String {
        var parts = [score.spec.rangeLabel == "\(score.spec.primary)" ? nil : score.spec.rangeLabel,
                     String(format: score.samples > 1 ? "avg +%.1f dB" : "+%.1f dB", score.noiseRiseDB),
                     score.peakNoiseRiseDB.flatMap { $0 - score.noiseRiseDB >= 1 ? String(format: "peak +%.0f", $0) : nil },
                     "\(score.contenders) contending"].compactMap { $0 }
        if score.isDFS { parts.append("DFS") }
        return parts.joined(separator: " · ")
    }
}

struct GradeBadge: View {
    let grade: Grade
    var size: CGFloat = 30

    var body: some View {
        Text(grade.rawValue)
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.grade(grade)))
            .accessibilityLabel("Grade \(grade.rawValue)")
    }
}
