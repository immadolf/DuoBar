@preconcurrency import CoreWLAN
import Foundation

/// A small event-driven wrapper around Apple's CoreWLAN API. Reading the radio
/// power state does not require Location authorization or a nearby network scan.
/// This helper never changes Wi-Fi power; it only observes radio/link state.
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

    // RSSI is read only on startup, link/radio changes, or when the app
    // wakes. Monitoring every link-quality event caused unnecessary CPU work
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
}
