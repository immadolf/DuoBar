# DuoBar Lite — AppKit-only experiment

A deliberately minimal **battery + network + volume** menu-bar glyph, developed as an independent executable within a fork of [DuoBar](https://github.com/Mikeli7666/DuoBar). It does **not** replace or patch the original DuoBar app.

## What it does

- **Outer ring:** MacBook battery level, including while connected to power (never switches to a CPU/memory/thermal visualization). Charging/connected power shows a small bolt. The ring gap, arc thickness, center Wi-Fi arcs and curved four-dot row use the numerical geometry from DuoBar 1.3.2.
- **Center:** Wi-Fi / Ethernet / disconnected network state via `NWPathMonitor`. CoreWLAN supplies radio power, link events and RSSI-based signal strength (strong/medium/weak). RSSI is refreshed when opening the menu or when the Wi-Fi link changes; no high-frequency quality monitoring, network scans or SSID/Location requests.
- **Four lower dots:** Default audio output volume via CoreAudio, with mute support.
- **Click icon:** Native NSMenu with a Wi-Fi checkbox toggle, Wi-Fi Settings shortcut, battery/network/volume and output device, Sound Settings shortcut, and Quit. Merely opening the menu never changes Wi-Fi power.
- **No** SwiftUI, NSPopover, Adaptive Ring sampling, general CPU monitoring, memory monitoring, Bluetooth scanning, nearby Wi-Fi scanning, or external dependencies.
- **Event-driven:** IOKit battery notifications (+ 60-second safety net), Network framework route updates, CoreWLAN radio/link events (not frequent RSSI-quality notifications), and CoreAudio property listeners (default output, devices, volume, mute, device alive). Short 0.3s animations use a 30 fps timer only during transition; no idle animation timer. Network glyphs never overlap: the old center fades out before the new one fades in. An immutable snapshot drives every image.

## Wi-Fi and audio controls

Click the glyph and choose **Wi-Fi** (checked = on). The CoreWLAN power toggle is only called on explicit click. If macOS rejects it, a dialog explains the error and provides **Open Wi-Fi Settings**. Turning Wi-Fi off may disconnect your Mac; use the switch with care.

The output device name and scalar volume (when available) are shown in the native menu. CoreAudio device-change events cover AirPods, USB, HDMI and DisplayPort output changes. On devices that do not expose scalar volume, the dots are inactive and **Sound Settings** offers a fallback. No automatic device picker or microphone access.

## Building locally

Requires macOS 13 or later and Xcode with its command-line tools:

```sh
cd Lite
./build.sh
open "build/DuoBar Lite.app"
```

The build script creates a self-contained, ad-hoc-signed app bundle. You can run ten volume quantization assertions and render six synthetic UI states without system changes:

```sh
./build.sh
./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --self-test
```

Preview PNGs appear in `build/fixtures/`. The test process does not start a menu bar service. Read-only Wi-Fi probe (never toggles the radio): `./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --probe-wifi`. Read-only native menu wiring and audio output probe: `./build/"DuoBar Lite.app"/Contents/MacOS/DuoBarLite --probe-menu`. **Not notarized or packaged as an official release.** To start at login, add the built app manually through macOS Login Items. You can run it alongside official DuoBar because it has a distinct app name and bundle identifier (`com.immadolf.DuoBarLite`).

## Resource measurements

On one 16 GB Apple silicon MacBook Pro running macOS 27.2, version 0.2.0's Physical Footprint was approximately 12 MB after one minute. Early 0.3.0 RSSI event monitoring cost about 1.5% of one CPU core and reached 20 MB physical footprint. After removing high-frequency quality events, a 61-second test measured about 0.08% of a CPU core and 12.6 MB Physical Footprint on the test machine. Test results depend on macOS and hardware. These readings are snapshots on one machine, not a universal performance guarantee. Validate battery, network, audio, and menu-bar visuals on your own hardware before considering this production-ready.

## 0.3.1 visual fix

Previously, transitions between disconnected, Wi-Fi, and Ethernet states painted both glyphs into the same frame with blended opacity, making the center look like several icons superimposed. Now the old glyph fades completely before the new one appears. The `--self-test` fixture includes seven stages of offline-to-Wi-Fi transition. Battery-ring and volume-dot transitions remain smooth and independent.

## Deliberate trade-offs

- No output-device picker, Wi-Fi joining, nearby network list, battery history, permanent animations, menu-bar tuning, or settings UI.
- Center Wi-Fi, outer ring, and audio-dot geometry use upstream measured ratios. Ethernet/offline/charging use SF Symbols and are not pixel-identical. Short state transitions are implemented; complex choreography and temporary AirPods glyphs remain intentionally omitted.
- Some USB / HDMI audio devices do not expose a scalar volume property, in which case volume is shown as unavailable.
- No automatic updates, signing certificate, or notarization.

Local source and build location: `~/opt/DuoBarLite/Lite`. The app is launched from `~/opt/DuoBarLite/Lite/build/DuoBar Lite.app`; rebuilding requires restarting this application. The original `/Applications/DuoBar.app` is separate.

The original upstream project and license are retained in the fork. This small implementation is distributed under the same MIT license as DuoBar; see the repository root `LICENSE`.
