<div align="center">

<img src="docs/currentflow-banner.svg" alt="CurrentFlow — native power monitoring for Mac" width="100%" />

# CurrentFlow · 电流脉动

**See the watts. Follow the flow.**

[**Download for Mac ↗**](https://github.com/kyox215/CurrentFlow/releases/latest) · [中文](README.md) · [Changelog](CHANGELOG.md) · [MIT](LICENSE)

`macOS 13+` · `Apple Silicon` · `SwiftUI` · `Local only`

</div>

A native SwiftUI menu bar app with a compact 420pt-wide light panel. Live system watts appear directly in the menu bar. The panel connects three nodes: power input on the left, system board at the upper right, and battery at the lower right. Watts take priority; amps and volts are secondary.

---

**Latest: [v0.9.0](https://github.com/kyox215/CurrentFlow/releases/tag/v0.9.0).** CPU/GPU and internal-backlight watts join the compact panel. Details adds Wi-Fi reference watts, fan RPM and the top three app/process CPU power estimates. Sampling runs only where needed. [Download and introduction](https://www.chinatech.in/currentflow) · [Chinese update copy](docs/updates/0.9.0.zh-CN.txt).

![CurrentFlow panel using explicitly labeled demo data](docs/preview.png)


<details>
<summary>Details preview (demo data)</summary>

![Wi-Fi reference watts, fan RPM and app CPU estimates using labeled demo data](docs/details.png)

</details>

## Features

- Compact, content-sized menu bar watts with a 16pt icon; live input, battery and whole-system power readings.
- CPU/GPU average watts and internal display-backlight watts in one row; unavailable or stale readings show a dash.
- Directional animations for charging, discharging and combined adapter/battery supply.
- Details-only Wi-Fi reference watts, actual fan RPM and top-three app/process CPU estimates; process scans run every two seconds only while Details is visible.
- Adjustable 0.5–300 second sampling, with saved preferences.
- Launch at login through macOS `SMAppService`, with approval status and a System Settings shortcut.
- Silent menu bar startup, with an optional “show panel on launch” setting.
- Details expand the panel automatically, showing a one-minute whole-system power chart in watts and adapter power limit. Collapse restores the compact panel.
- Notch-aware positioning, scrolling when screen space is limited, and reduced-motion support.
- Local-only operation: no account, network requests, telemetry, root access or additional driver.

## Install

Prebuilt packages target **Apple Silicon and macOS 13 or later**.

Download a DMG or ZIP from [chinatech.in](https://www.chinatech.in/currentflow) or [Releases](https://github.com/kyox215/CurrentFlow/releases/latest), move `电流脉动.app` into Applications, and open it there. Click its menu bar icon or watt reading to open the panel.

The release is **ad-hoc signed and not Developer ID notarized**. macOS may report an unidentified developer. You can inspect the source and build locally instead. Release checksums are provided.

The gear menu contains “开机自启” (launch at login) and “启动时展开面板” (show panel on launch). Both default to off. Enable the first and leave the second off for silent login startup. macOS may require approval in Login Items; the app reports this rather than pretending approval has already been granted. The first launch opens the panel once.

## Reading the diagram

Blue carries external power to the system. Green flows into the battery. Orange flows out of the battery toward the system. The board node displays **whole-system power**, not a separately measured motherboard rail.

Readings are DC measurements inside the Mac, not AC wall-outlet measurements. Input and battery currents use different voltage domains and cannot be subtracted directly. Independent sensor updates may make instantaneous power values differ. An idle battery can legitimately remain at zero.

The app reads eight allowlisted AppleSMC keys (`B0AC`, `B0AV`, `ID0R`, `VD0R`, `PDTR`, `PSTR`, `PBwo`, `PDBR`) and reads `wiPm`, `F0Ac`, `F1Ac` only while Details is visible. Power readings fall back to IOKit properties. It contains no SMC write, fan-control or charging-control path. These hardware fields are not a stable public Apple contract; unsupported readings remain unavailable or are clearly labeled as cached/estimated. Sampling faster does not force hardware to update faster.

CPU/GPU watts are computed from aggregate IOReport energy-counter deltas divided by actual elapsed time. They are marked `≈` as interval-average model estimates. Known CLPC report IDs are used only on macOS 27.0/27.0.1; unknown versions/drivers are not guessed. Display power covers the internal backlight, not the entire display module or external monitors. These components do not sum to whole-system watts. See [third-party notices](THIRD_PARTY_NOTICES.txt).

Wi-Fi is a reference sensor value: on the tested Mac it stayed near 0.033 W during a 4 MB Wi-Fi transfer, so it is not presented as an accurate live wireless power measurement. App/process rankings use `rusage_info_v6.ri_energy_nj` deltas as CPU-side average estimates, aggregate app Helpers, and do not represent total app energy. Closing Details stops process scans; reopening establishes a fresh baseline.

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
build/电流脉动.app/Contents/MacOS/CurrentFlow --process-power
build/电流脉动.app/Contents/MacOS/CurrentFlow --startup-status
build/电流脉动.app/Contents/MacOS/CurrentFlow --render-preview artifacts
```

There are 229 checks for parsing, sensor decoding, fallback behavior, window placement and detail resizing, sampling, history and startup settings. Login-item registration/removal, saved launch preferences and silent cold startup have also been tested locally. The operating system was not logged out or rebooted for these checks.

Screenshots and animations in `docs/` use labeled demo data. See [CONTRIBUTING](CONTRIBUTING.md) before reporting compatibility issues; do not post battery serial numbers or full IORegistry dumps.

## License

[MIT](LICENSE) © 2026 kyox215.
