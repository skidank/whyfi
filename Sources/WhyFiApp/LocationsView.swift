import SwiftUI
import WhyFiCore

/// Save scores at several spots, then find the channel that works everywhere.
struct LocationsView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save a scan at each spot where you use Wi-Fi, then compare.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Name this spot (e.g. Kitchen)", text: $newName)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !model.canSaveLocation)
                }
                Text("Saves the current \(model.scoreWindow == .now ? "live" : model.scoreWindow.rawValue) scores (\(model.windowSampleCount) sweep\(model.windowSampleCount == 1 ? "" : "s")). Wait for a few sweeps first.")
                    .font(.caption2).foregroundStyle(.secondary)
                List {
                    ForEach(model.locations.snapshots) { snap in
                        LocationRow(snap: snap)
                    }
                }
                .listStyle(.bordered)
                if let e = model.locations.lastError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(10)
            .frame(width: 300)
            Divider()
            ComparisonTable()
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, model.canSaveLocation else { return }
        model.saveLocation(named: name)
        newName = ""
    }
}

private struct LocationRow: View {
    @Environment(AppModel.self) private var model
    let snap: LocationSnapshot
    @State private var name = ""

    var body: some View {
        let store = model.locations
        HStack {
            Toggle("", isOn: Binding(
                get: { store.compared.contains(snap.id) },
                set: { if $0 { store.compared.insert(snap.id) } else { store.compared.remove(snap.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit { store.rename(snap.id, to: name) }
                Text("\(snap.date.formatted(date: .abbreviated, time: .shortened)) · \(snap.sweeps) sweep\(snap.sweeps == 1 ? "" : "s") · \(snap.networks.count) networks")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.remove(snap.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this location")
        }
        .onAppear { name = snap.name }
    }
}

private struct ComparisonTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let snaps = model.locations.comparedSnapshots
        let rows = LocationComparison.combine(snaps, band: model.band, width: model.width, includeDFS: model.includeDFS)
        VStack(alignment: .leading, spacing: 6) {
            Picker("Width", selection: $model.width) {
                ForEach(model.widthsForBand) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let best = rows.first {
                HStack(spacing: 8) {
                    GradeBadge(grade: best.worstGrade, size: 22)
                    Text("Best everywhere: ch \(best.spec.primary)").font(.headline)
                    Button("Show on Spectrum") { model.pinnedSpec = best.spec }
                }
            }
            if snaps.isEmpty {
                Text("Save at least one location and tick it to compare.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Channel") { r in
                        Text(r.spec.rangeLabel == "\(r.spec.primary)" ? "\(r.spec.primary)" : "\(r.spec.primary)  (\(r.spec.rangeLabel))")
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Worst") { r in
                        HStack(spacing: 6) {
                            GradeBadge(grade: r.worstGrade, size: 18)
                            Text(String(format: "+%.1f dB", r.worstNoiseRiseDB)).monospacedDigit()
                        }
                    }
                    .width(90)
                    TableColumn("Average") { Text(String(format: "+%.1f dB", $0.meanNoiseRiseDB)).monospacedDigit() }
                        .width(70)
                    TableColumnForEach(snaps) { snap in
                        TableColumn(snap.name) { (r: CombinedScore) in
                            if let s = r.perLocation[snap.id] {
                                HStack(spacing: 4) {
                                    GradeBadge(grade: s.grade, size: 16)
                                    Text(String(format: "+%.1f", s.noiseRiseDB)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .width(min: 70, ideal: 90)
                    }
                    TableColumn("Notes") { Text($0.isDFS ? "DFS" : "").foregroundStyle(.secondary) }
                }
                Text("Ranked by each channel's worst location, so the top pick is good everywhere you saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}
