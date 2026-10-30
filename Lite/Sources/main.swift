import AppKit
import CoreAudio
import IOKit.ps
import Network

// A deliberately small menu-bar companion: no SwiftUI, popover, performance
// telemetry, Bluetooth scanning, Wi-Fi enumeration, or accessibility permission.
struct Status: Equatable {
    var charge: Double?
    var onAC = false
    var charging = false
    var networkUp = false
    var networkKind: NetworkKind = .other
    var volume: Double?
    var muted = false

    enum NetworkKind: Equatable { case wifi, ethernet, other }
}

private final class DuoBarLite: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status = Status()
    private let statusItem = NSStatusBar.system.statusItem(withLength: GlyphRenderer.statusItemWidth)
    private let menu = NSMenu()
    private let batteryItem = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
    private let networkItem = NSMenuItem(title: "Network", action: nil, keyEquivalent: "")
    private let volumeItem = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")

    private var batterySource: CFRunLoopSource?
    private var batteryFallback: Timer?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "DuoBarLite.network", qos: .utility)

    private let audioQueue = DispatchQueue(label: "DuoBarLite.audio", qos: .utility)
    private var audioDevice = AudioDeviceID(kAudioObjectUnknown)
    private var audioDeviceAddresses: [AudioObjectPropertyAddress] = []
    private var audioSystemListenerInstalled = false
    private lazy var audioListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.updateAudio() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateBattery()
        updateAudio()
        configureBatteryNotifications()
        configureAudioNotifications()
        configureNetworkMonitor()
        redraw()
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        batteryFallback?.invalidate()
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .commonModes)
        }
        if audioSystemListenerInstalled {
            var address = audioAddress(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, audioListener)
        }
        detachAudioDeviceListeners()
    }

    private func configureMenu() {
        // The native NSMenu is the only interactive UI; do not instantiate a
        // separate window or NSHostingView until such features are actually needed.
        for item in [batteryItem, networkItem, volumeItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DuoBar Lite", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Battery · Network · Volume"
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let charge = status.charge {
            batteryItem.title = "Battery: \(Int((charge * 100).rounded()))%\(status.charging ? " · Charging" : status.onAC ? " · AC Power" : "")"
        } else {
            batteryItem.title = "Battery: Unavailable"
        }
        let transport = status.networkKind == .wifi ? "Wi-Fi" : status.networkKind == .ethernet ? "Ethernet" : "Network"
        networkItem.title = "\(transport): \(status.networkUp ? "Connected" : "Disconnected")"
        if let volume = status.volume {
            volumeItem.title = "Volume: \(status.muted ? "Muted" : "\(Int((volume * 100).rounded()))%")"
        } else {
            volumeItem.title = "Volume: Unavailable"
        }
    }

    private func configureBatteryNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<DuoBarLite>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.updateBattery() }
        }, context)?.takeRetainedValue() {
            batterySource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        // Slow safety-net for OS/device combinations that miss notifications.
        batteryFallback = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
        batteryFallback?.tolerance = 10
    }

    private func updateBattery() {
        let old = status
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject] else {
            status.charge = nil
            if status != old { redraw() }
            return
        }
        var found = false
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                let current = raw[kIOPSCurrentCapacityKey] as? NSNumber,
                let capacity = raw[kIOPSMaxCapacityKey] as? NSNumber, capacity.doubleValue > 0 else { continue }
            status.charge = min(1, max(0, current.doubleValue / capacity.doubleValue))
            status.charging = (raw[kIOPSIsChargingKey] as? Bool) ?? false
            status.onAC = (raw[kIOPSPowerSourceStateKey] as? String) == (kIOPSACPowerValue as String)
            found = true
            break
        }
        if !found { status.charge = nil; status.charging = false; status.onAC = false }
        if status != old { redraw() }
    }

    private func configureNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let kind: Status.NetworkKind =
                path.usesInterfaceType(.wifi) ? .wifi :
                path.usesInterfaceType(.wiredEthernet) ? .ethernet : .other
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let old = self.status
                self.status.networkUp = up
                self.status.networkKind = kind
                if self.status != old { self.redraw() }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func audioAddress(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                              channel: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: channel)
    }

    private func readFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           channel: UInt32) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = audioAddress(selector, channel: channel)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readMute(_ device: AudioObjectID, channel: UInt32) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = audioAddress(kAudioDevicePropertyMute, channel: channel)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private func defaultAudioDevice() -> AudioDeviceID {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = audioAddress(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return device
    }

    private func configureAudioNotifications() {
        var address = audioAddress(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        audioSystemListenerInstalled =
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                audioQueue, audioListener) == noErr
        updateAudio()
    }

    private func detachAudioDeviceListeners() {
        guard audioDevice != AudioDeviceID(kAudioObjectUnknown) else { return }
        for var address in audioDeviceAddresses {
            AudioObjectRemovePropertyListenerBlock(audioDevice, &address, audioQueue, audioListener)
        }
        audioDeviceAddresses.removeAll()
    }

    private func rebindAudioDevice(_ device: AudioDeviceID) {
        guard audioDevice != device else { return }
        detachAudioDeviceListeners()
        audioDevice = device
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return }
        for channel: UInt32 in [0, 1, 2] {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = audioAddress(selector, channel: channel)
                if AudioObjectAddPropertyListenerBlock(device, &address, audioQueue, audioListener) == noErr {
                    audioDeviceAddresses.append(address)
                }
            }
        }
    }

    private func updateAudio() {
        let old = status
        let device = defaultAudioDevice()
        rebindAudioDevice(device)
        if device == AudioDeviceID(kAudioObjectUnknown) {
            status.volume = nil
            status.muted = false
        } else {
            // Some drivers expose channel 0; others expose only channels 1 and 2.
            var levels: [Float32] = []
            for channel: UInt32 in [0, 1, 2] {
                if let value = readFloat(device, kAudioDevicePropertyVolumeScalar, channel: channel) {
                    levels.append(value)
                    if channel == 0 { break }
                }
            }
            status.volume = levels.isEmpty ? nil : Double(levels.reduce(0, +) / Float32(levels.count))
            status.muted = [UInt32(0), 1, 2].contains { channel in readMute(device, channel: channel) }
        }
        if status != old { redraw() }
    }

    private func redraw() {
        statusItem.button?.image = GlyphRenderer.image(for: status)
    }

}

if CommandLine.arguments.contains("--self-test") {
    // No app window, process observers or permissions are involved in this mode.
    precondition(GlyphRenderer.activeDotCount(volume: nil, muted: false) == nil)
    precondition(GlyphRenderer.activeDotCount(volume: 0, muted: false) == 0)
    precondition(GlyphRenderer.activeDotCount(volume: 0.01, muted: false) == 1)
    precondition(GlyphRenderer.activeDotCount(volume: 0.25, muted: false) == 1)
    precondition(GlyphRenderer.activeDotCount(volume: 0.26, muted: false) == 2)
    precondition(GlyphRenderer.activeDotCount(volume: 0.50, muted: false) == 2)
    precondition(GlyphRenderer.activeDotCount(volume: 0.75, muted: false) == 3)
    precondition(GlyphRenderer.activeDotCount(volume: 1.0, muted: false) == 4)
    precondition(GlyphRenderer.activeDotCount(volume: 1.0, muted: true) == 0)
    precondition(GlyphRenderer.activeDotCount(volume: .nan, muted: false) == nil)

    let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    let fixtures: [(String, Status)] = [
        ("wifi-on-battery", Status(charge: 0.72, networkUp: true, networkKind: .wifi,
                                   volume: 0.70)),
        ("wifi-charging", Status(charge: 0.45, onAC: true, charging: true, networkUp: true,
                                 networkKind: .wifi, volume: 0.30)),
        ("wifi-full", Status(charge: 1.0, onAC: true, networkUp: true,
                             networkKind: .wifi, volume: 1)),
        ("ethernet-muted", Status(charge: 0.93, networkUp: true, networkKind: .ethernet,
                                  volume: 0.84, muted: true)),
        ("offline-low-battery", Status(charge: 0.08, networkUp: false, volume: 0.05)),
        ("unavailable", Status())
    ]
    var distinctImages = Set<Data>()
    for (name, snapshot) in fixtures {
        let width = Int(GlyphRenderer.imageSize.width * 4)
        let height = Int(GlyphRenderer.imageSize.height * 4)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                           pixelsHigh: height, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let drawingContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create bitmap test context")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = drawingContext
        drawingContext.cgContext.scaleBy(x: 4, y: 4)
        GlyphRenderer.draw(snapshot, in: CGRect(origin: .zero, size: GlyphRenderer.imageSize),
                           context: drawingContext.cgContext)
        drawingContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let composited = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                                pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let compositedContext = NSGraphicsContext(bitmapImageRep: composited),
              let image = bitmap.cgImage else { fatalError("Could not composite PNG") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = compositedContext
        compositedContext.cgContext.setFillColor(NSColor.white.cgColor)
        compositedContext.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        compositedContext.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        compositedContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = composited.representation(using: .png, properties: [:]), bytes.count > 200 else {
            fatalError("Invalid PNG test fixture")
        }
        distinctImages.insert(bytes)
        try bytes.write(to: fixtureDirectory.appendingPathComponent(name + ".png"))
        print("rendered: " + name + ".png (" + String(bytes.count) + " bytes)")
    }
    precondition(distinctImages.count >= 4, "Different UI states must render differently")
    print("PASS: 10 volume tests; 6 image fixtures; different states change pixels")
} else {
    let application = NSApplication.shared
    let delegate = DuoBarLite()
    application.delegate = delegate
    application.run()
}
