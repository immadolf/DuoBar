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
    var wifiOn: Bool?
    var wifiRSSI: Int?
    var networkKind: NetworkKind = .other
    var volume: Double?
    var muted = false
    var audioOutputName: String?

    enum NetworkKind: Equatable { case wifi, ethernet, other }
}

private final class DuoBarLite: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status = Status()
    private let statusItem = NSStatusBar.system.statusItem(withLength: GlyphRenderer.statusItemWidth)
    private let menu = NSMenu()
    private let wifiToggleItem = NSMenuItem(title: "Wi-Fi", action: nil, keyEquivalent: "")
    private let openWiFiSettingsItem = NSMenuItem(title: "Wi-Fi Settings…", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
    private let networkItem = NSMenuItem(title: "Network", action: nil, keyEquivalent: "")
    private let volumeItem = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
    private let audioOutputItem = NSMenuItem(title: "Audio Output", action: nil, keyEquivalent: "")
    private let openSoundSettingsItem = NSMenuItem(title: "Sound Settings…", action: nil, keyEquivalent: "")

    private let wifi = WiFiController()
    private var wakeObserver: NSObjectProtocol?
    private var animationTimer: Timer?
    private var animationStart: TimeInterval = 0
    private var animationFrom: Status?
    private let animationDuration = 0.30

    private var batterySource: CFRunLoopSource?
    private var batteryFallback: Timer?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "DuoBarLite.network", qos: .utility)

    private let audioQueue = DispatchQueue(label: "DuoBarLite.audio", qos: .utility)
    private var audioDevice = AudioDeviceID(kAudioObjectUnknown)
    private var audioDeviceAddresses: [AudioObjectPropertyAddress] = []
    private var audioSystemListenerAddresses: [AudioObjectPropertyAddress] = []
    private lazy var audioListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.updateAudio() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        wifi.onChange = { [weak self] in self?.refreshWiFiState() }
        refreshWiFiState(animated: false)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshWiFiState()
            self?.updateBattery()
            self?.updateAudio()
        }
        updateBattery()
        updateAudio()
        configureBatteryNotifications()
        configureAudioNotifications()
        configureNetworkMonitor()
        redraw()
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        animationTimer?.invalidate()
        animationTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wifi.onChange = nil
        batteryFallback?.invalidate()
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .commonModes)
        }
        for var address in audioSystemListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, audioListener)
        }
        audioSystemListenerAddresses.removeAll()
        detachAudioDeviceListeners()
    }

    private func configureMenu() {
        // The first menu entry is a real Wi-Fi radio switch. An additional
        // Settings shortcut provides recovery if the OS rejects the CoreWLAN
        // change. Merely opening the menu never changes the Wi-Fi power state.
        wifiToggleItem.target = self
        wifiToggleItem.action = #selector(toggleWiFiPower)
        menu.addItem(wifiToggleItem)

        openWiFiSettingsItem.target = self
        openWiFiSettingsItem.action = #selector(openWiFiSettings)
        menu.addItem(openWiFiSettingsItem)

        menu.addItem(.separator())
        for item in [batteryItem, networkItem, volumeItem, audioOutputItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        openSoundSettingsItem.target = self
        openSoundSettingsItem.action = #selector(openSoundSettings)
        menu.addItem(openSoundSettingsItem)

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

    func runReadOnlyMenuProbe() {
        configureMenu()
        refreshWiFiState(animated: false)
        updateBattery()
        updateAudio()
        menuNeedsUpdate(menu)
        precondition(wifiToggleItem.action == #selector(toggleWiFiPower))
        precondition(wifiToggleItem.target === self)
        precondition(openWiFiSettingsItem.action == #selector(openWiFiSettings))
        print("MENU_PROBE radio=\(wifiToggleItem.title) checked=\(wifiToggleItem.state == .on) enabled=\(wifiToggleItem.isEnabled)")
        print("MENU_PROBE \(batteryItem.title)")
        print("MENU_PROBE \(networkItem.title) (route probe inactive)")
        print("MENU_PROBE \(volumeItem.title)")
        print("MENU_PROBE \(audioOutputItem.title)")
        print("MENU_PROBE toggle action wired; Wi-Fi radio unchanged")
    }

    @objc private func toggleWiFiPower() {
        // Recheck on click. The currently routed connection may be Ethernet,
        // so NWPathMonitor's path status is NOT the radio power state.
        let before = wifi.snapshot()
        guard before.available else {
            showWiFiError(WiFiController.PowerError.interfaceUnavailable)
            return
        }
        do {
            let after = try wifi.setPower(!before.poweredOn)
            applyWiFiState(after)
        } catch {
            refreshWiFiState()
            showWiFiError(error)
        }
    }

    @objc private func openWiFiSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showWiFiError(_ error: Error) {
        // Error feedback is only instantiated after an actual user action
        // fails, so normal idle operation does not allocate a window.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not change Wi-Fi state"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Wi-Fi Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openWiFiSettings() }
    }

    private func refreshWiFiState(animated: Bool = true) {
        applyWiFiState(wifi.snapshot(), animated: animated)
    }

    private func applyWiFiState(_ snapshot: WiFiController.Snapshot, animated: Bool = true) {
        let old = status
        status.wifiOn = snapshot.available ? snapshot.poweredOn : nil
        // Only publish when the displayed signal-strength band changes.
        // Tiny RSSI fluctuations should not restart icon animations.
        status.wifiRSSI = snapshot.rssi.map { $0 >= -65 ? -55 : $0 >= -75 ? -70 : -85 }
        if old != status {
            if animated { transition(from: old) } else { redraw() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshWiFiState()
        let snapshot = wifi.snapshot()
        wifiToggleItem.isEnabled = snapshot.available
        wifiToggleItem.title = snapshot.available ? "Wi-Fi" : "Wi-Fi (Unavailable)"
        wifiToggleItem.state = snapshot.poweredOn && snapshot.available ? .on : .off

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
            volumeItem.title = "Volume: Device-controlled / Unavailable"
        }
        audioOutputItem.title = "Audio Output: " + (status.audioOutputName ?? "Unavailable")
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
            if status != old { transition(from: old) }
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
        if status != old { transition(from: old) }
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
                if self.status != old { self.transition(from: old) }
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

    private func currentAudioOutputName(_ device: AudioDeviceID) -> String? {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        var address = audioAddress(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
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
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = audioAddress(selector, scope: kAudioObjectPropertyScopeGlobal)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   audioQueue, audioListener) == noErr {
                audioSystemListenerAddresses.append(address)
            }
        }
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
        var aliveAddress = audioAddress(kAudioDevicePropertyDeviceIsAlive,
                                         scope: kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(device, &aliveAddress, audioQueue, audioListener) == noErr {
            audioDeviceAddresses.append(aliveAddress)
        }
    }

    private func updateAudio() {
        let old = status
        let device = defaultAudioDevice()
        rebindAudioDevice(device)
        status.audioOutputName = currentAudioOutputName(device)
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
        if status != old { transition(from: old) }
    }

    private func redraw() {
        statusItem.button?.image = GlyphRenderer.image(for: status)
    }

    private func transition(from previous: Status) {
        guard previous != status else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            redraw()
            return
        }
        animationFrom = previous
        animationStart = ProcessInfo.processInfo.systemUptime
        updateAnimatedImage()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateAnimatedImage()
        }
        timer.tolerance = 0.006
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateAnimatedImage() {
        guard let previous = animationFrom else {
            animationTimer?.invalidate()
            animationTimer = nil
            redraw()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStart
        let progress = min(1, max(0, elapsed / animationDuration))
        statusItem.button?.image = GlyphRenderer.image(for: status, from: previous,
                                                        progress: CGFloat(progress))
        if progress >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
            animationFrom = nil
        }
    }

}

if CommandLine.arguments.contains("--probe-menu") {
    _ = NSApplication.shared
    let probe = DuoBarLite()
    probe.runReadOnlyMenuProbe()
} else if CommandLine.arguments.contains("--probe-wifi") {
    let service = WiFiController()
    let snapshot = service.snapshot()
    print("WIFI_READ_ONLY available=\(snapshot.available) poweredOn=\(snapshot.poweredOn) rssi=\(snapshot.rssi.map(String.init) ?? "unavailable")")
    // Don't invoke setPower here: changing Wi-Fi could disrupt remote access.
} else if CommandLine.arguments.contains("--self-test") {
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
    let initial = Status(charge: 0.25, networkUp: true, networkKind: .wifi, volume: 0.25)
    let target = Status(charge: 0.85, onAC: true, charging: true,
                        networkUp: true, networkKind: .wifi, volume: 0.85)
    let middle = GlyphRenderer.image(for: target, from: initial, progress: 0.5)
    precondition(middle.tiffRepresentation != nil, "Animated middle frame must render")
    // Check all phases of a network-state transition. Specifically exercise
    // offline -> Wi-Fi, which previously overpainted two different glyphs.
    let offline = Status(charge: 0.72, networkUp: false, networkKind: .other, volume: 0.5)
    let online = Status(charge: 0.72, networkUp: true, wifiOn: true, wifiRSSI: -55,
                        networkKind: .wifi, volume: 0.5)
    for phase: CGFloat in [0, 0.15, 0.35, 0.5, 0.65, 0.85, 1] {
        let frame = GlyphRenderer.image(for: online, from: offline, progress: phase)
        precondition(frame.tiffRepresentation != nil, "Network transition frame must render")
    }
    print("PASS: 7 offline-to-Wi-Fi transition phases")
    print("PASS: 10 volume tests; 6 image fixtures; animated midpoint renders")
} else {
    let application = NSApplication.shared
    let delegate = DuoBarLite()
    application.delegate = delegate
    application.run()
}
