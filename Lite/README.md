# DuoBar Lite — AppKit-only experiment

A deliberately minimal **battery + network + volume** menu-bar glyph, developed as an independent executable within a fork of [DuoBar](https://github.com/Mikeli7666/DuoBar). It does **not** replace or patch the original DuoBar app.

## What it does

- **Outer ring:** MacBook battery level, including while connected to power (never switches to a CPU/memory/thermal visualization).
- **Center:** Wi-Fi / Ethernet / disconnected network state via `NWPathMonitor`.
- **Four lower dots:** Default audio output volume via CoreAudio, with mute support.
- **Click icon:** Native, small NSMenu showing battery/network/volume and a Quit command.
- **No** SwiftUI, NSPopover, Adaptive Ring sampling, general CPU monitoring, memory monitoring, Bluetooth scanning, nearby Wi-Fi scanning, or external dependencies.
- **Event-driven:** IOKit battery notifications (+ a 60-second fallback), Network framework path updates, and CoreAudio property listeners. Redraws happen only when a relevant status value changes.

## Building locally

Requires macOS 13 or later and Xcode with its command-line tools:

```sh
cd Lite
./build.sh
open "build/DuoBar Lite.app"
```

The build script creates a self-contained, ad-hoc-signed app bundle. **Not notarized or packaged as an official release.** To start at login, add the built app manually through macOS Login Items. You can run it alongside official DuoBar because it has a distinct app name and bundle identifier (`com.immadolf.DuoBarLite`).

## Resource measurements

On one 16 GB Apple silicon MacBook Pro running macOS 27.2, the prototype's **Physical Footprint** was **12.8 MB** shortly after launch and **12.4 MB** after approximately 80 seconds. These readings are snapshots on one machine, not a universal performance guarantee. Validate battery, network, audio, and menu-bar visuals on your own hardware before considering this production-ready.

## Deliberate trade-offs

- No output-device picker, Wi-Fi joining, nearby network list, battery history, animations, menu-bar tuning, or settings UI.
- Center icon uses the system SF Symbols rather than DuoBar's full SwiftUI glyph composition; the appearance is similar in concept but **not pixel-identical**.
- Some USB / HDMI audio devices do not expose a scalar volume property, in which case volume is shown as unavailable.
- No automatic updates, signing certificate, or notarization.

The original upstream project and license are retained in the fork. This small implementation is distributed under the same MIT license as DuoBar; see the repository root `LICENSE`.
