import CoreLocation
import Foundation
import Observation

/// macOS redacts SSID, BSSID and beacon data unless the app holds Location authorization.
@MainActor @Observable
public final class LocationGate: NSObject {
    public enum State: Equatable { case unknown, authorized, denied }

    public private(set) var state: State = .unknown
    @ObservationIgnored private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        update(manager.authorizationStatus)
    }

    public func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    private func update(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: state = .authorized
        case .denied, .restricted: state = .denied
        default: state = .unknown
        }
    }
}

extension LocationGate: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { update(status) }
    }
}
