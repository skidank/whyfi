import SwiftUI
import WhyFiCore

struct NetworkTable: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var sortOrder = [KeyPathComparator(\NetRow.latest.rssi, order: .reverse)]
    @State private var allBands = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Table(rows, selection: $model.selectedBSSID, sortOrder: $sortOrder) {
                Group {
                    TableColumn("Network", value: \NetRow.displaySSID) { r in
                        HStack(spacing: 4) {
                            if model.isOwn(r.record) { Image(systemName: "house.fill").foregroundStyle(Theme.own).help("Your network") }
                            Text(r.displaySSID).italic(r.isHidden)
                        }
                        .foregroundStyle(r.isStale ? .secondary : .primary)
                    }
                    .width(min: 120, ideal: 170)
                    TableColumn("BSSID", value: \NetRow.id) { Text($0.id).font(.callout.monospaced()) }
                        .width(min: 120, ideal: 135)
                    TableColumn("Vendor", value: \NetRow.vendorLabel) { r in
                        Text(r.vendor?.label ?? "—")
                            .help(r.vendor?.inferred == true ? "Virtual BSSID; maker inferred from related MAC addresses" : "")
                    }
                    .width(min: 60, ideal: 90)
                    TableColumn("Band", value: \NetRow.latest.band) { Text($0.latest.band.rawValue) }
                        .width(55)
                    TableColumn("Ch", value: \NetRow.latest.channel) { Text("\($0.spec.primary)").monospacedDigit() }
                        .width(36)
                    TableColumn("Width", value: \NetRow.spec.width) { r in Text(r.spec.segments.count > 1 ? "80+80" : "\(r.spec.width.rawValue)").monospacedDigit() }
                        .width(44)
                }
                Group {
                    TableColumn("Signal", value: \NetRow.latest.rssi) { r in SignalCell(rssi: r.isScorable ? r.latest.rssi : nil, estimated: r.isReported) }
                        .width(min: 80, ideal: 95)
                    TableColumn("Gen", value: \NetRow.generation) { Text($0.generation) }
                        .width(60)
                    TableColumn("Security", value: \NetRow.latest.security) { Text($0.latest.security) }
                        .width(min: 60, ideal: 85)
                    TableColumn("Util", value: \NetRow.utilizationSort) { r in
                        Text(r.ies?.bssLoad.map { "\(Int(($0.channelUtilization * 100).rounded()))%" } ?? "—").monospacedDigit()
                    }
                    .width(40)
                    TableColumn("Clients", value: \NetRow.stationSort) { r in
                        Text(r.ies?.bssLoad.map { "\($0.stationCount)" } ?? "—").monospacedDigit()
                    }
                    .width(46)
                    TableColumn("Seen", value: \NetRow.lastSeen) { r in
                        Text(r.isReported ? "reported" : r.isStale ? "\(r.sweepsMissed) sweeps ago" : "now").foregroundStyle(.secondary)
                            .help(r.isReported ? "Announced by \(r.reportedBy ?? "a nearby AP") but not heard directly; "
                                  + (r.isScorable ? "signal estimated from the same device's other radio" : "signal unknown, not used in scoring") : "")
                    }
                    .width(min: 50, ideal: 80)
                }
            }
            HStack {
                Toggle("Show all bands", isOn: $allBands).toggleStyle(.checkbox)
                Spacer()
                Text("\(rows.count) networks · Util and Clients come from the AP's own BSS Load report, when it sends one")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var rows: [NetRow] {
        let q = search.lowercased()
        return model.records.map { NetRow(record: $0, vendor: model.vendors[$0.id]) }
            .filter { allBands || $0.latest.band == model.band }
            .filter { q.isEmpty || $0.displaySSID.lowercased().contains(q) || $0.id.contains(q) }
            .sorted(using: sortOrder)
    }
}

struct SignalCell: View {
    /// nil = unknown (reported by another AP, not co-located).
    let rssi: Int?
    var estimated = false

    var body: some View {
        let rssi = self.rssi ?? -100
        HStack(spacing: 6) {
            Text(self.rssi == nil ? "?" : estimated ? "≈\(rssi)" : "\(rssi)").monospacedDigit()
            GeometryReader { g in
                let frac = CGFloat(min(max(Double(rssi + 100) / 70, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.secondary.opacity(0.7)).frame(width: max(2, g.size.width * frac))
                }
            }
            .frame(height: 4)
        }
        .help(self.rssi == nil ? "Signal unknown: announced by another AP, not heard directly" : "\(rssi) dBm")
    }
}

/// A table row: the record plus its vendor, so the Vendor column can sort by name.
@dynamicMemberLookup
struct NetRow: Identifiable {
    let record: BSSRecord
    let vendor: Vendor?

    var id: String { record.id }
    /// Unknown vendors sort last.
    var vendorLabel: String { vendor?.name ?? "\u{10FFFF}" }

    subscript<T>(dynamicMember path: KeyPath<BSSRecord, T>) -> T { record[keyPath: path] }
}

extension BSSRecord {
    var utilizationSort: Double { ies?.bssLoad?.channelUtilization ?? -1 }
    var stationSort: Int { ies?.bssLoad?.stationCount ?? -1 }
}
