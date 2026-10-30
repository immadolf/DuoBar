# DuoBar Lite — AppKit-only experiment

A deliberately minimal **battery + network + volume** menu-bar glyph, developed as an independent executable within a fork of [DuoBar](https://github.com/Mikeli7666/DuoBar). It does **not** replace or patch the original DuoBar app.

## What it does

- **Outer ring:** MacBook battery level, including while connected to power (never switches to a CPU/memory/thermal visualization). Charging/connected power shows a small bolt. The ring gap, arc thickness, center Wi-Fi arcs and curved four-dot row use the numerical geometry from DuoBar 1.3.2.
- **Center:** Wi-Fi / Ethernet / disconnected network state via `NWPathMonitor`. Wi-Fi is drawn as a native, three-part CoreGraphics icon (not a SwiftUI SF Symbol). To avoid CoreWLAN polling/Location permissions, it does not distinguish signal-strength levels.
- **Four lower dots:** Default audio output volume via CoreAudio, with mute support.
- **Click icon:** Native, small NSMenu showing battery/network/volume and a Quit command.
- **No** SwiftUI, NSPopover, Adaptive Ring sampling, general CPU monitoring, memory monitoring, Bluetooth scanning, nearby Wi-Fi scanning, or external dependencies.
- **Event-driven:** IOKit battery notifications (+ a 60-second fallback), Network framework path updates, and CoreAudio property listeners. Redraws happen only when a relevant status value changes. The icon uses a captured immutable state snapshot so deferred NSImage drawing never reads mutable application state.

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

Preview PNGs appear in `build/fixtures/`. The test process does not start a menu bar service. **Not notarized or packaged as an official release.** To start at login, add the built app manually through macOS Login Items. You can run it alongside official DuoBar because it has a distinct app name and bundle identifier (`com.immadolf.DuoBarLite`).

## Resource measurements

On one 16 GB Apple silicon MacBook Pro running macOS 27.2, version 0.1.0's **Physical Footprint** was **12.8 MB** shortly after launch and **12.4 MB** after approximately 80 seconds. These readings are snapshots on one machine, not a universal performance guarantee. Validate battery, network, audio, and menu-bar visuals on your own hardware before considering this production-ready.

## Deliberate trade-offs

- No output-device picker, Wi-Fi joining, nearby network list, battery history, animations, menu-bar tuning, or settings UI.
- Center Wi-Fi, outer ring, and audio-dot geometry are ported from the upstream measured ratios. Ethernet/offline/charging still use SF Symbols and the appearance is **not pixel-identical**; smooth transition animations and temporary AirPods glyphs are intentionally omitted.
- Some USB / HDMI audio devices do not expose a scalar volume property, in which case volume is shown as unavailable.
- No automatic updates, signing certificate, or notarization.

The original upstream project and license are retained in the fork. This small implementation is distributed under the same MIT license as DuoBar; see the repository root `LICENSE`.
