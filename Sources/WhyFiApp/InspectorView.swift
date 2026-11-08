import Charts
import SwiftUI
import WhyFiCore
import WhyFiScan

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Your connection") {
                    if let l = model.link, l.isAssociated {
                        LinkDetails(link: l)
                        RSSIChart(samples: model.linkHistory, color: Theme.own)
                    } else {
                        Text("Not connected to Wi-Fi.").foregroundStyle(.secondary)
                    }
                }
                section("Selected network") {
                    if let r = model.selectedRecord {
                        NetworkDetails(record: r, isOwn: model.isOwn(r), vendor: model.vendors[r.id])
                        RSSIChart(samples: r.history, color: Theme.selected)
                    } else {
                        Text("Click a network in the spectrum or table.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Rows: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(.secondary)
                    Text(v).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

private struct LinkDetails: View {
    let link: LinkStatus

    var body: some View {
        Rows(rows: [
            ("Network", link.ssid ?? "—"),
            ("BSSID", link.bssid ?? "—"),
            ("Channel", [link.channel.map { "\($0)" }, link.width?.label, link.band?.rawValue].compactMap { $0 }.joined(separator: " · ")),
            ("Signal", "\(link.rssi) dBm"),
            ("Noise", link.noise != 0 ? "\(link.noise) dBm" : "—"),
            ("SNR", link.snr.map { "\($0) dB (\(snrQuality($0)))" } ?? "—"),
            ("Tx rate", String(format: "%.0f Mbps", link.transmitRateMbps)),
            ("Tx power", "\(link.transmitPowerMW) mW"),
            ("Mode", link.phyMode),
            ("Security", link.security),
            ("Country", link.countryCode ?? "—"),
        ])
    }

    private func snrQuality(_ snr: Int) -> String {
        switch snr {
        case 40...: "excellent"
        case 25..<40: "good"
        case 15..<25: "fair"
        default: "poor"
        }
    }
}

private struct NetworkDetails: View {
    let record: BSSRecord
    let isOwn: Bool
    let vendor: Vendor?

    var body: some View {
        let o = record.latest, s = record.spec, ie = record.ies
        var rows: [(String, String)] = [
            ("Network", record.displaySSID + (isOwn ? " (yours)" : "")),
            ("BSSID", record.id),
            ("Vendor", vendor.map { $0.inferred ? "\($0.name) (inferred)" : $0.name } ?? "Unknown"),
            ("Band", o.band.rawValue),
            ("Channel", "\(s.primary)" + (s.rangeLabel == "\(s.primary)" ? "" : " (spans \(s.rangeLabel))")),
            ("Width", s.segments.count > 1 ? "80+80 MHz" : s.width.label),
            ("Frequency", s.segments.map { String(format: "%.0f–%.0f MHz", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")),
            ("Signal", record.isScorable ? "\(record.isReported ? "≈" : "")\(o.rssi) dBm (avg \(Int(record.smoothedRSSI.rounded())))" : "Unknown"),
            ("Generation", record.generation),
            ("Security", o.security),
            ("Beacon", "\(o.beaconInterval) TU"),
        ]
        if let l = ie?.bssLoad {
            rows.append(("Clients", "\(l.stationCount)"))
            rows.append(("Airtime busy", "\(Int((l.channelUtilization * 100).rounded()))%"))
        }
        if record.isReported {
            rows.append(("Source", "Announced by \(record.reportedBy ?? "a nearby AP"); "
                         + (record.isScorable ? "signal estimated" : "signal unknown, not scored")))
        }
        if let n = ie?.reducedNeighbors.count, n > 0 { rows.append(("Announces", "\(n) other radio\(n == 1 ? "" : "s")")) }
        if ChannelPlan.isDFS(band: o.band, channel: s.primary) { rows.append(("Notes", "DFS channel")) }
        if let cc = o.countryCode ?? ie?.countryCode { rows.append(("Country", cc)) }
        rows.append(("First seen", record.firstSeen.formatted(date: .omitted, time: .standard)))
        rows.append(("Last seen", record.lastSeen.formatted(date: .omitted, time: .standard)))
        return Rows(rows: rows)
    }
}

struct RSSIChart: View {
    let samples: [RSSISample]
    let color: Color

    var body: some View {
        // Relative minutes read better than clock times for a short session, and never collide.
        let now = samples.last?.time ?? .now
        Chart(samples) {
            LineMark(x: .value("Minutes ago", $0.time.timeIntervalSince(now) / 60), y: .value("Signal (dBm)", $0.rssi))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: -100 ... -20)
        .chartYAxisLabel("dBm")
        .chartXAxisLabel("minutes ago")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel { Text(v.as(Double.self).map { String(format: "%.0f", abs($0)) } ?? "") }
            }
        }
        .frame(height: 130)
        .overlay {
            if samples.count < 2 { Text("Collecting history…").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
