# WhyFi — notes for Claude

macOS Wi-Fi analyzer (SwiftUI + CoreWLAN) that recommends the best AP channel. See README.md for features and scoring.

## Commands

- `make run` — build, assemble and sign `build/WhyFi.app`, then launch it. Use this to check UI changes.
- `make test` — unit tests (Swift Testing). Run after any change to `WhyFiCore`.
- `swift build` — quick compile check (debug, no bundle).
- `make icon` — regenerate `Support/AppIcon.icns` (committed; `make build` doesn't rebuild it) after editing `Support/Icon/make-icon.swift`.

## Architecture

- `WhyFiCore` — Foundation only, fully unit-tested. `ChannelPlan` (frequencies, blocks, DFS/PSC, operating classes), `InformationElements` (beacon IE parser: BSS Load, HT/VHT/HE/EHT operation, RNR), `NetworkModel`/`BSSRecord` (per-BSSID state, staleness, own-network detection, RNR-reported neighbours), `Scorer` (noise-rise scoring, time aggregation, ranking), `LocationComparison`, `VendorDatabase`.
- `WhyFiScan` — the only code that touches CoreWLAN/CoreLocation. `WiFiScanner` converts `CWNetwork`/`CWInterface` into Sendable value types (`ScanObservation`, `LinkStatus`) on one serial queue; CoreWLAN objects must never leave it. `LocationGate` handles authorization.
- `WhyFiApp` — SwiftUI. `AppModel` (`@MainActor @Observable`) owns the scan loop, interferer history, rescoring and vendor cache; `LocationStore` persists saved locations as JSON in Application Support. Views: `SpectrumView` (custom `Canvas`), `RecommendationStrip`, `NetworkTable`, `RankingTable`, `LocationsView`, `InspectorView`.

Put new logic in `WhyFiCore` with tests where possible; keep the app layer thin.

## Platform facts (verified on real hardware; don't re-derive)

- Without Location authorization, macOS redacts SSID, BSSID, IE data and noise — nearly everything. Authorization requires a signed `.app` bundle with `NSLocationWhenInUseUsageDescription`; a bare `swift run` binary gets nothing useful.
- `scanForNetworks` blocks ~7 s for a real sweep and then serves cached results for ~12 s (returning in <0.1 s). The scan loop treats calls longer than 1 s as fresh sweeps and ignores cache hits after the first.
- `cachedScanResults` is a growing union of everything seen recently, so don't treat it as "now".
- `CWNetwork.noiseMeasurement` is 0 except for the associated network.
- CoreWLAN's `CWChannelWidth` tops out at 160 MHz; 320 MHz comes only from the EHT Operation IE.
- APs derive extra BSSIDs (guest SSIDs, other radios) by setting the locally-administered bit and tweaking octets. Own-network detection and vendor inference rely on this.

## Gotchas

- Don't name a type `Observation`; it collides with the Observation framework that the `@Observable` macro expands into. (That's why it's `ScanObservation`.)
- SwiftUI's `.inspector` broke the main layout here (content overflowed the window). The details panel is a plain `HStack` side column instead.
- Keep toolbar items from pushing each other around: the window title is removed (`.toolbar(removing: .title)`) so the status pill can size to its content.
- SourceKit often reports "No such module 'WhyFiCore'" in editors; that's a false positive. `swift build` is the source of truth.
- Strict Swift 6 concurrency is on. All CoreWLAN calls go through `WiFiScanner`'s single serial queue; `link()` skips (returns nil) while a scan is running rather than waiting behind it.
- `Scorer`'s `noiseFloorDBm` is per 20 MHz; scoring scales it by channel width. `AppModel.noiseFloor` normalizes the link's measured noise to 20 MHz.
- Saved `locations.json` must keep decoding across releases: `ChannelScore.init(from:)` uses `decodeIfPresent` for anything added later, and `LocationStore` moves an unreadable file aside instead of overwriting it.
- Synthetic clicks via accessibility automation don't trigger `SpatialTapGesture` on the spectrum `Canvas`; test spectrum click and hover with a real mouse.

## Privacy

This repo is public. Never commit real BSSIDs or SSIDs (they can be geolocated through public Wi-Fi databases), scan exports, signing identities or personal emails. Tests use made-up MAC addresses.
