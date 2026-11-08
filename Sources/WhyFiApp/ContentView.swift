import SwiftUI
import WhyFiCore
import WhyFiScan

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.networks
    @State private var showInspector = true
    @State private var search = ""

    enum Tab: String, CaseIterable { case networks = "Networks", ranking = "Channel Ranking", locations = "Locations" }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            main
            if showInspector {
                Divider()
                InspectorView().frame(width: 310)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter networks")
        .toolbar { toolbar }
        // The name is already in the menu bar; without it the status pill can size to its text without shoving anything.
        .toolbar(removing: .title)
        .onAppear { model.locationChanged() }
        .onChange(of: model.location.state) { model.locationChanged() }
    }

    private var main: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            if !model.hasLocationAccess { LocationBanner() }
            RecommendationStrip()
                .padding(.horizontal)
                .padding(.top, 10)
            SpectrumView()
                .frame(height: 300)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 6)
            Group {
                switch tab {
                case .networks: NetworkTable(search: search)
                case .ranking: RankingTable()
                case .locations: LocationsView()
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .principal) {
            Picker("Band", selection: $model.band) {
                ForEach(Band.allCases) { b in
                    Text("\(b.rawValue) (\(model.network.active.filter { $0.latest.band == b }.count))").tag(b)
                }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .navigation) { ScanStatus() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isPaused.toggle()
            } label: {
                Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.isPaused ? "Resume scanning" : "Pause scanning")
            Menu {
                Picker("Scan Interval", selection: $model.scanInterval) {
                    ForEach([10.0, 20, 30, 60], id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                }
                Divider()
                Toggle("Recommend DFS Channels", isOn: $model.includeDFS)
                Toggle("Ignore My Own Network", isOn: $model.excludeOwn)
                Toggle("Show Networks No Longer Heard", isOn: $model.showStale)
                Divider()
                Button("Export Scan Data…") { model.exportScans() }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .help("Scan and scoring options")
            Button {
                showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
        }
    }
}

struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
                if model.isScanning && !model.isPaused {
                    ProgressView().controlSize(.small)
                }
                Text(text(now: ctx.date))
                    .font(.callout)
                    .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
        }
    }

    private func text(now: Date) -> String {
        if let e = model.lastError { return e }
        if model.isPaused { return "Paused" }
        guard let last = model.network.lastSweep else { return model.hasLocationAccess ? "Scanning…" : "Waiting for Location access" }
        let s = Int(now.timeIntervalSince(last))
        return "Sweep \(model.network.sweepCount) · \(s) s ago"
    }
}

struct LocationBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("WhyFi needs Location access to see Wi-Fi networks").font(.headline)
                Text("macOS hides network names, hardware addresses and beacon details from apps without it. WhyFi never reads or stores your location.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.location.state == .denied {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(LocationGate.settingsURL) }
            } else {
                Button("Allow Access") { model.location.request() }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}
