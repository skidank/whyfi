import SwiftUI
import WhyFiCore

/// Each BSS drawn as a trapezoid spanning its occupied spectrum, height = signal strength.
struct SpectrumView: View {
    @Environment(AppModel.self) private var model
    @State private var hover: CGPoint?

    struct Item {
        let id: String
        let label: String
        let spec: ChannelSpec
        let rssi: Double
        let isOwn: Bool
        let isStale: Bool
        let isReported: Bool
        let vendor: String?
    }

    var body: some View {
        let band = model.band
        // Reported BSSes with unknown signal can't be placed on a dBm axis.
        let items = model.records
            .filter { $0.latest.band == band && $0.isScorable }
            .map { Item(id: $0.id, label: $0.displaySSID, spec: $0.spec, rssi: $0.smoothedRSSI,
                        isOwn: model.isOwn($0), isStale: $0.isStale, isReported: $0.isReported,
                        vendor: model.vendors[$0.id]?.label) }
            .sorted { $0.rssi < $1.rssi }
        let geo = SpectrumGeometry(band: band)
        GeometryReader { proxy in
            let frame = geo.layout(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    draw(&ctx, frame: frame, geo: geo, items: items)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hover = p } else { hover = nil }
                }
                .gesture(SpatialTapGesture().onEnded { v in
                    model.selectedBSSID = hit(v.location, frame: frame, items: items)?.id
                })
                if let h = hover, let item = hit(h, frame: frame, items: items) {
                    Tooltip(item: item)
                        .position(x: min(max(h.x, 110), proxy.size.width - 110), y: max(h.y - 50, 40))
                        .allowsHitTesting(false)
                }
                if items.isEmpty {
                    Text(model.network.sweepCount == 0 ? "Waiting for the first scan…" : "No networks heard on \(band.rawValue)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectrum of \(items.count) networks on \(band.rawValue)")
    }

    private func hit(_ p: CGPoint, frame: SpectrumFrame, items: [Item]) -> Item? {
        let f = frame.freq(atX: p.x)
        return items
            .filter { item in item.spec.segments.contains { $0.contains(f) } && p.y >= frame.y(item.rssi) - 6 && p.y <= frame.plot.maxY }
            .min { abs(p.y - frame.y($0.rssi)) < abs(p.y - frame.y($1.rssi)) }
    }

    private func draw(_ ctx: inout GraphicsContext, frame: SpectrumFrame, geo: SpectrumGeometry, items: [Item]) {
        let plot = frame.plot

        // dBm grid
        for dbm in stride(from: -90, through: -30, by: 10) {
            let y = frame.y(Double(dbm))
            ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                       with: .color(Theme.grid), lineWidth: 0.5)
            ctx.draw(Text("\(dbm)").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
        ctx.draw(Text("dBm").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 6, y: plot.minY - 8), anchor: .trailing)

        // DFS region
        if geo.band == .ghz5 {
            let r = CGRect(x: frame.x(5250), y: plot.minY, width: frame.x(5730) - frame.x(5250), height: plot.height)
            ctx.fill(Path(r), with: .color(.secondary.opacity(0.06)))
            ctx.draw(Text("DFS (radar detection required)").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: r.midX, y: plot.maxY - 8))
        }

        // Recommendation
        if let rec = model.highlightedSpec, rec.band == geo.band {
            for s in rec.segments {
                let r = CGRect(x: frame.x(s.lowerBound), y: plot.minY, width: frame.x(s.upperBound) - frame.x(s.lowerBound), height: plot.height)
                ctx.fill(Path(r), with: .color(Theme.recommended.opacity(0.10)))
                ctx.stroke(Path(r), with: .color(Theme.recommended.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            ctx.draw(Text(rec == model.pinnedSpec ? "Selected channel" : "Recommended").font(.caption.bold()).foregroundStyle(Theme.recommended),
                     at: CGPoint(x: frame.x((rec.lowMHz + rec.highMHz) / 2), y: plot.minY + 22))
        }

        // Networks, weakest first so the strong ones sit on top.
        for item in items {
            let selected = item.id == model.selectedBSSID
            let color = selected ? Theme.selected : item.isOwn ? Theme.own : Theme.neighbour
            for seg in item.spec.segments {
                let path = trapezoid(seg, rssi: item.rssi, frame: frame)
                ctx.fill(path, with: .color(color.opacity(selected ? 0.25 : item.isOwn ? 0.16 : 0.07)))
                ctx.stroke(path, with: .color(color.opacity(item.isStale ? 0.35 : 0.9)),
                           style: StrokeStyle(lineWidth: selected ? 2.5 : item.isOwn ? 2 : 1.25, lineJoin: .round,
                                              dash: item.isStale ? [3, 3] : item.isReported ? [6, 3] : []))
            }
        }

        // Labels: selected and own first, then strongest; skip any that would collide.
        var placed: [CGRect] = []
        let selectedID = model.selectedBSSID
        let ordered = items.sorted { a, b in
            func rank(_ i: Item) -> Int { i.id == selectedID ? 0 : i.isOwn ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.rssi > b.rssi
        }
        for item in ordered where !item.isStale {
            let seg = item.spec.segments[0]
            let text = Text(item.isReported ? "\(item.label) (reported)" : item.label)
                .font(.caption2.weight(item.isOwn ? .semibold : .regular)).italic(item.isReported)
            let resolved = ctx.resolve(text)
            let size = resolved.measure(in: CGSize(width: 200, height: 20))
            let center = CGPoint(x: frame.x((seg.lowerBound + seg.upperBound) / 2), y: frame.y(item.rssi) - size.height / 2 - 2)
            let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height).insetBy(dx: -2, dy: -1)
            guard rect.minY > plot.minY - 4, !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            ctx.draw(resolved, at: center)
        }

        // Channel axis
        let scores = Dictionary(uniqueKeysWithValues: (model.channelScores[geo.band] ?? []).map { ($0.spec.primary, $0) })
        for ch in ChannelPlan.twentyMHzChannels(geo.band) {
            let x = frame.x(ChannelPlan.centerMHz(band: geo.band, channel: ch))
            let major = geo.isMajor(ch)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.maxY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY + (major ? 5 : 3))) },
                       with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            if geo.showsLabel(ch) {
                ctx.draw(Text("\(ch)").font(.caption2.weight(major ? .bold : .regular)).foregroundStyle(major ? .primary : .secondary),
                         at: CGPoint(x: x, y: plot.maxY + 13))
            }
            // Per-channel grade strip
            if let s = scores[ch] {
                let spacing = geo.band == .ghz2_4 ? 5.0 : 20.0
                let w = max(2, frame.x(ChannelPlan.centerMHz(band: geo.band, channel: ch) + spacing) - x - 2)
                let r = CGRect(x: x - w / 2, y: plot.maxY + 22, width: w, height: 10)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.grade(s.grade).opacity(0.85)))
            }
        }
        ctx.draw(Text("Channel").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 6, y: plot.maxY + 13), anchor: .trailing)
        ctx.draw(Text("Grade").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 6, y: plot.maxY + 27), anchor: .trailing)
        ctx.stroke(Path(plot), with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
    }

    private func trapezoid(_ seg: ClosedRange<Double>, rssi: Double, frame: SpectrumFrame) -> Path {
        let ramp = min(4, (seg.upperBound - seg.lowerBound) * 0.12)
        let floor = frame.plot.maxY, top = frame.y(rssi)
        return Path { p in
            p.move(to: CGPoint(x: frame.x(seg.lowerBound), y: floor))
            p.addLine(to: CGPoint(x: frame.x(seg.lowerBound + ramp), y: top))
            p.addLine(to: CGPoint(x: frame.x(seg.upperBound - ramp), y: top))
            p.addLine(to: CGPoint(x: frame.x(seg.upperBound), y: floor))
        }
    }
}

struct SpectrumGeometry {
    let band: Band

    func layout(in size: CGSize) -> SpectrumFrame {
        let plot = CGRect(x: 52, y: 14, width: max(10, size.width - 64), height: max(10, size.height - 14 - 40))
        return SpectrumFrame(plot: plot, range: band.displayRange)
    }

    func isMajor(_ ch: Int) -> Bool {
        switch band {
        case .ghz2_4: [1, 6, 11].contains(ch)
        case .ghz5: false
        case .ghz6: ChannelPlan.isPSC(band: band, channel: ch)
        }
    }

    func showsLabel(_ ch: Int) -> Bool { band != .ghz6 || isMajor(ch) }
}

struct SpectrumFrame {
    let plot: CGRect
    let range: ClosedRange<Double>
    static let topDBm = -20.0, floorDBm = -100.0

    func x(_ mhz: Double) -> CGFloat {
        plot.minX + CGFloat((mhz - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.width
    }

    func freq(atX x: CGFloat) -> Double {
        range.lowerBound + Double((x - plot.minX) / plot.width) * (range.upperBound - range.lowerBound)
    }

    func y(_ dbm: Double) -> CGFloat {
        let t = (Self.topDBm - min(max(dbm, Self.floorDBm), Self.topDBm)) / (Self.topDBm - Self.floorDBm)
        return plot.minY + CGFloat(t) * plot.height
    }
}

private struct Tooltip: View {
    let item: SpectrumView.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.label).font(.callout.weight(.semibold))
            Text(item.id + (item.vendor.map { " · \($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("ch \(item.spec.primary) · \(item.spec.width.label) · \(item.isReported ? "≈" : "")\(Int(item.rssi.rounded())) dBm\(item.isOwn ? " · yours" : "")")
                .font(.caption)
            if item.isReported {
                Text("Announced by a nearby AP; not heard directly").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2)
    }
}
