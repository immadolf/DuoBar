@preconcurrency import CoreWLAN
import Foundation

/// A small event-driven wrapper around Apple's CoreWLAN API. Reading the radio
/// power state does not require Location authorization or a nearby network scan.
/// Wi-Fi ON/OFF only happens in response to the user's explicit menu action.
final class WiFiController: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    var onChange: (() -> Void)?
    private var subscribedEvents: [CWEventType] = []

    struct Snapshot: Equatable {
        var available: Bool
        var poweredOn: Bool
        var rssi: Int?
    }

    override init() {
        super.init()
        client.delegate = self
        for event: CWEventType in [.powerDidChange, .linkDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
                subscribedEvents.append(event)
            } catch {
                NSLog("[DuoBarLite] Cannot observe Wi-Fi event %ld: %@", event.rawValue, String(describing: error))
            }
        }
    }

    // RSSI is read only on startup, link/radio changes, or when the menu
    // opens. Monitoring every link-quality event caused unnecessary CPU work
    // from CoreWLAN/airportd on macOS 27.2.
    func snapshot() -> Snapshot {
        guard let interface = client.interface() else {
            return Snapshot(available: false, poweredOn: false, rssi: nil)
        }
        let poweredOn = interface.powerOn()
        let rssi = interface.rssiValue()
        return Snapshot(available: true, poweredOn: poweredOn,
                        rssi: poweredOn && (-100 ... -1).contains(rssi) ? rssi : nil)
    }

    /// Synchronous CoreWLAN operation; query state again rather than assuming
    /// a successful return means the radio has already changed state.
    func setPower(_ desired: Bool) throws -> Snapshot {
        guard let interface = client.interface() else {
            throw PowerError.interfaceUnavailable
        }
        try interface.setPower(desired)
        let newState = snapshot()
        guard newState.available && newState.poweredOn == desired else {
            throw PowerError.stateMismatch
        }
        return newState
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        notifyUpdate()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        notifyUpdate()
    }

    func clientConnectionInterrupted() { notifyUpdate() }
    func clientConnectionInvalidated() { notifyUpdate() }

    private func notifyUpdate() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    deinit {
        for event in subscribedEvents {
            try? client.stopMonitoringEvent(with: event)
        }
        if client.delegate === self { client.delegate = nil }
    }

    enum PowerError: LocalizedError {
        case interfaceUnavailable
        case stateMismatch
        var errorDescription: String? {
            switch self {
            case .interfaceUnavailable: "No Wi-Fi interface was found."
            case .stateMismatch: "macOS did not apply the requested Wi-Fi power state."
            }
        }
    }
}
