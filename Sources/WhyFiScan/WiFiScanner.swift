import CoreWLAN
import Foundation
import os
import WhyFiCore

/// Status of the Mac's own Wi-Fi link.
public struct LinkStatus: Sendable, Hashable {
    public var interfaceName: String
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int
    public var noise: Int
    public var transmitRateMbps: Double
    public var transmitPowerMW: Int
    public var band: Band?
    public var channel: Int?
    public var width: ChannelWidth?
    public var phyMode: String
    public var security: String
    public var countryCode: String?
    public var time: Date

    public var isAssociated: Bool { channel != nil && rssi != 0 }
    public var snr: Int? { noise != 0 ? rssi - noise : nil }
}

public struct ScanResult: Sendable {
    public var sweep: Sweep
    public var duration: TimeInterval
    /// CoreWLAN serves results from cache for ~12 s after a real sweep; those return almost instantly.
    public var isFresh: Bool { duration > 1 }
}

/// Wraps CoreWLAN. All CW objects stay inside this type; callers only see value types.
/// CoreWLAN makes no thread-safety promises, so every call goes through one serial queue.
public final class WiFiScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.skidank.WhyFi.wlan")
    private let client = CWWiFiClient.shared()
    /// Scans enqueued or running (a count, since pause/resume can leave two queued), so link polls can skip
    /// instead of queueing behind a ~7 s sweep.
    private let scansPending = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    private var interface: CWInterface? { client.interface() }

    /// Blocks for a full multi-band sweep (~7 s) unless results are cached.
    public func scan() async throws -> ScanResult {
        scansPending.withLock { $0 += 1 }
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                defer { scansPending.withLock { $0 -= 1 } }
                guard let iface = interface else {
                    cont.resume(throwing: ScanError.noInterface)
                    return
                }
                let start = Date()
                do {
                    let nets = try iface.scanForNetworks(withSSID: nil, includeHidden: true)
                    let obs = nets.compactMap(Self.observation)
                    cont.resume(returning: ScanResult(sweep: Sweep(time: Date(), observations: obs),
                                                      duration: Date().timeIntervalSince(start)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Current link status, or nil while a scan holds the radio (callers keep their last value).
    public func link() async -> LinkStatus? {
        if scansPending.withLock({ $0 > 0 }) { return nil }
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                cont.resume(returning: interface.map(Self.linkStatus))
            }
        }
    }

    /// Every (band, channel, width) the interface is allowed to use in the current regulatory domain.
    public func supportedCandidates() async -> [Candidate] {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                let chans = interface?.supportedWLANChannels() ?? []
                cont.resume(returning: chans.compactMap { ch in
                    guard let band = Self.band(ch.channelBand), let width = Self.width(ch.channelWidth) else { return nil }
                    return Candidate(band: band, primary: ch.channelNumber, width: width)
                })
            }
        }
    }

    public enum ScanError: Error, LocalizedError {
        case noInterface
        public var errorDescription: String? { "No Wi-Fi interface found." }
    }

    // MARK: - Conversion

    static func band(_ b: CWChannelBand) -> Band? {
        switch b {
        case .band2GHz: .ghz2_4
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: nil
        }
    }

    static func width(_ w: CWChannelWidth) -> ChannelWidth? {
        switch w {
        case .width20MHz: .w20
        case .width40MHz: .w40
        case .width80MHz: .w80
        case .width160MHz: .w160
        default: nil
        }
    }

    static func observation(_ n: CWNetwork) -> ScanObservation? {
        guard let bssid = n.bssid, let ch = n.wlanChannel, let band = band(ch.channelBand) else { return nil }
        return ScanObservation(bssid: bssid.lowercased(), ssid: n.ssid, rssi: n.rssiValue, noise: n.noiseMeasurement,
                           band: band, channel: ch.channelNumber, width: width(ch.channelWidth) ?? .w20,
                           beaconInterval: n.beaconInterval, security: security(of: n),
                           countryCode: n.countryCode, ieData: n.informationElementData)
    }

    /// Strongest mode first, so mixed-mode networks report their best.
    private static let securityOrder: [(CWSecurity, String)] = [
        (.wpa3Enterprise, "WPA3 Enterprise"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA2/WPA3"),
        (.wpa2Enterprise, "WPA2 Enterprise"), (.wpa2Personal, "WPA2"), (.wpaEnterpriseMixed, "WPA/WPA2 Ent."),
        (.wpaPersonalMixed, "WPA/WPA2"), (.wpaEnterprise, "WPA Enterprise"), (.wpaPersonal, "WPA"),
        (.OWE, "OWE"), (.oweTransition, "OWE Transition"), (.dynamicWEP, "Dynamic WEP"), (.WEP, "WEP"),
        (.none, "Open"),
    ]

    static func security(of n: CWNetwork) -> String {
        securityOrder.first { n.supportsSecurity($0.0) }?.1 ?? "Unknown"
    }

    static func securityName(_ s: CWSecurity) -> String {
        securityOrder.first { $0.0 == s }?.1 ?? "Unknown"
    }

    static func phyName(_ m: CWPHYMode) -> String {
        switch m {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n (Wi-Fi 4)"
        case .mode11ac: "802.11ac (Wi-Fi 5)"
        case .mode11ax: "802.11ax (Wi-Fi 6)"
        case .mode11be: "802.11be (Wi-Fi 7)"
        default: "—"
        }
    }

    static func linkStatus(_ i: CWInterface) -> LinkStatus {
        let ch = i.wlanChannel()
        return LinkStatus(interfaceName: i.interfaceName ?? "en0", ssid: i.ssid(), bssid: i.bssid()?.lowercased(),
                          rssi: i.rssiValue(), noise: i.noiseMeasurement(), transmitRateMbps: i.transmitRate(),
                          transmitPowerMW: i.transmitPower(), band: ch.flatMap { band($0.channelBand) },
                          channel: ch?.channelNumber, width: ch.flatMap { width($0.channelWidth) },
                          phyMode: phyName(i.activePHYMode()), security: securityName(i.security()),
                          countryCode: i.countryCode(), time: Date())
    }
}
