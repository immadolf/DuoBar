# DuoBar Lite — passive AppKit menu-bar indicator

A lightweight, independent AppKit/CoreGraphics implementation of the [DuoBar](https://github.com/Mikeli7666/DuoBar) three-in-one status glyph. It retains only the battery ring, network indicator, and four volume dots. It **does not replace** the original DuoBar application.

## Behavior

- **Battery:** outer ring displays current battery percentage and charging state, including when plugged in. It never switches to CPU/memory/thermal readings.
- **Network:** center glyph represents Wi-Fi, Ethernet, or disconnected state. Wi-Fi signal-strength bands are read through CoreWLAN on startup, radio/link changes, or wake; no nearby network scanning, SSID requests or Location authorization.
- **Audio:** bottom four dots reflect default output-device volume/mute when supported by CoreAudio; changes to audio devices are observed.
- **Only interaction:** clicking the menu-bar icon opens **one native menu item — “Quit DuoBar Lite”**. No Wi-Fi power toggle, device controls, settings buttons, status popover, or action on the icon itself.
- **Visual transitions:** short 0.3-second animations for actual status changes, no always-running animation loop; respects Reduce Motion. Different center glyphs are shown sequentially, never composited on top of one another.
- **No SwiftUI**, Adaptive Ring performance collection, Bluetooth scans, or third-party dependencies. Status updates use native IOKit, Network, CoreWLAN, and CoreAudio notifications, plus a 60-second battery safety-net.

## Build and run

Requirements: macOS 13+ and Xcode command-line tools.

```sh
cd ~/opt/DuoBarLite/Lite
./build.sh
open "build/DuoBar Lite.app"
```

The build creates a locally ad-hoc-signed `DuoBar Lite.app` with an independent bundle identifier (`com.immadolf.DuoBarLite`). After rebuilding, **quit the running Lite app and launch it again**; the original DuoBar is unaffected.

Since the only menu action is Quit, you can also stop the Lite app through Activity Monitor.

## Diagnostics and tests

```sh
./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --self-test
./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --probe-menu
./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --probe-wifi
```

The self-test checks volume-dot thresholds, six static PNG fixtures and seven phases of offline-to-Wi-Fi transition. The menu test asserts there is exactly **one Quit entry**. Wi-Fi probing is **read-only**. None of these command-line tests intentionally toggles Wi-Fi or opens a control panel.

An earlier macOS 27.2 / 16 GB Apple silicon test measured roughly **12.6 MB Physical Footprint** and **0.08% of one CPU core** over about a minute after removing high-frequency CoreWLAN quality notifications. Performance depends on hardware and OS version; this is not a certified benchmark.

## Scope and limitations

- The icon uses some glyph geometry measured in upstream DuoBar v1.3.2 and SF Symbols for Ethernet/offline/charging. It is not a pixel-perfect clone of every transition.
- USB, DisplayPort, HDMI and other outputs might not expose software volume; the dots then display the unavailable state.
- No wireless network list, volume slider, audio-device picker, settings, Apple Developer ID signature, notarization, updates, or automatic startup.
- This project remains a **prototype**, not a verified production release.

This Fork retains the original project's MIT license, included at the repository root.
