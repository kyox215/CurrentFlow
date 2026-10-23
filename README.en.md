# CurrentFlow · 电流脉动

**See your Mac's live power draw and where its power is flowing.**

A native SwiftUI menu bar app with a compact 420 × 300 light panel. Live system watts appear directly in the menu bar. The panel connects three nodes: power input on the left, system board at the upper right, and battery at the lower right. Watts take priority; amps and volts are secondary.

[中文](README.md) · [Download](https://github.com/kyox215/CurrentFlow/releases/latest) · [MIT License](LICENSE)

**Latest: [v0.7.4](https://github.com/kyox215/CurrentFlow/releases/tag/v0.7.4).** Settings now omits the Demo and Live Hardware Data actions; normal operation reads hardware automatically. Recent releases also added a whole-system watt trend, automatic detail expansion, and a smaller menu bar item measuring about 73pt on the tested Mac for two-digit watt readings, down from 92pt. [Chinese update copy](docs/updates/0.7.4.zh-CN.txt).

![CurrentFlow panel using explicitly labeled demo data](docs/preview.png)

## Features

- Compact, content-sized menu bar watts with a 16pt icon; live input, battery and whole-system power readings.
- Directional animations for charging, discharging and combined adapter/battery supply.
- Adjustable 0.5–300 second sampling, with saved preferences.
- Launch at login through macOS `SMAppService`, with approval status and a System Settings shortcut.
- Silent menu bar startup, with an optional “show panel on launch” setting.
- Details expand the panel automatically, showing a one-minute whole-system power chart in watts and adapter power limit. Collapse restores the compact panel.
- Notch-aware positioning, scrolling when screen space is limited, and reduced-motion support.
- Local-only operation: no account, network requests, telemetry, root access or additional driver.

## Install

Prebuilt packages target **Apple Silicon and macOS 13 or later**.

Download a DMG or ZIP from [Releases](https://github.com/kyox215/CurrentFlow/releases/latest), move `电流脉动.app` into Applications, and open it there. Click its menu bar icon or watt reading to open the panel.

The release is **ad-hoc signed and not Developer ID notarized**. macOS may report an unidentified developer. You can inspect the source and build locally instead. Release checksums are provided.

The gear menu contains “开机自启” (launch at login) and “启动时展开面板” (show panel on launch). Both default to off. Enable the first and leave the second off for silent login startup. macOS may require approval in Login Items; the app reports this rather than pretending approval has already been granted. The first launch opens the panel once.

## Reading the diagram

Blue carries external power to the system. Green flows into the battery. Orange flows out of the battery toward the system. The board node displays **whole-system power**, not a separately measured motherboard rail.

Readings are DC measurements inside the Mac, not AC wall-outlet measurements. Input and battery currents use different voltage domains and cannot be subtracted directly. Independent sensor updates may make instantaneous power values differ. An idle battery can legitimately remain at zero.

The app reads six allowlisted AppleSMC keys (`B0AC`, `B0AV`, `ID0R`, `VD0R`, `PDTR`, `PSTR`) and falls back to IOKit power properties. It contains no SMC write, fan-control or charging-control path. These hardware fields are not a stable public Apple contract; unsupported readings remain unavailable or are clearly labeled as cached/estimated. Sampling faster does not force hardware to update faster.

## Build and verify

Requires macOS, Xcode / Command Line Tools and Swift 5.9+. No third-party dependencies.

```sh
git clone https://github.com/kyox215/CurrentFlow.git
cd CurrentFlow
bash scripts/build.sh
bash scripts/test.sh
```

The app is written to `build/电流脉动.app`; ZIP and DMG packages go into `artifacts/`. The script targets the host architecture. Intel and other hardware have not been comprehensively tested.

```sh
build/电流脉动.app/Contents/MacOS/CurrentFlow --snapshot
build/电流脉动.app/Contents/MacOS/CurrentFlow --startup-status
build/电流脉动.app/Contents/MacOS/CurrentFlow --render-preview artifacts
```

There are 157 checks for parsing, sensor decoding, fallback behavior, window placement and detail resizing, sampling, history and startup settings. Login-item registration/removal, saved launch preferences and silent cold startup have also been tested locally. The operating system was not logged out or rebooted for these checks.

Screenshots and animations in `docs/` use labeled demo data. See [CONTRIBUTING](CONTRIBUTING.md) before reporting compatibility issues; do not post battery serial numbers or full IORegistry dumps.

## License

[MIT](LICENSE) © 2026 kyox215.
