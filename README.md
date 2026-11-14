# EFStatus (v2.6.1)

A lightweight macOS menu bar app that shows real-time EcoFlow Delta 2 battery status — no phone app needed, no Node.js, no cloud subscriptions. Ships as a universal binary for Intel and Apple Silicon (macOS 13+).

![EFStatus menu bar icon and popup showing battery percent, watts in and out, and time remaining](cover.jpg)

> Running an older version? From 2.5.0 on, EFStatus updates itself: right-click the menu bar icon → **Check for Updates…**. On 2.4.0 or earlier, re-download it once from [Gumroad](https://bereto.gumroad.com/l/efstatus).

## What it shows

**Menu bar:** `EF⚡ 89%`

**Popup:**
- Battery % + remaining Wh + visual bar
- With an extra battery attached: a MAIN / EXTRA row with each pack's % and Wh (the Wh and time estimates cover every pack)
- Time to full / time to empty
- Live input watts (green) and output watts (red)
- Device model (DELTA 2 / DELTA 3 / DELTA PRO)

SOC is shown as `—` when EcoFlow has not sent a battery percentage (it is not displayed as `0%` unless the device actually reports 0). If the device or API is unreachable, the menu bar and popup show `—` / Lost connection instead of leftover numbers.

## How it works

Starting with v2.0.0, EFStatus connects to EcoFlow's real-time MQTT feed — the same channel used by the official app. Data updates the moment your device reports a change, instead of polling every 10 seconds.

If MQTT disconnects, goes quiet for 30 seconds, or the socket looks half-open (no inbound packets for 90 seconds), the app falls back to REST polling, shows offline honestly when REST also fails, and reconnects in the background. Each reconnect fetches a fresh MQTT certificate from EcoFlow instead of reusing a cached password.

On first launch (and whenever you change keys in Settings), **Save & Connect** checks the Access Key, Secret Key, and device SN against EcoFlow before the window closes. Empty fields still show “All fields are required.” Wrong keys or SN stay on Setup with the API error.

## Compatibility

**Confirmed working**
- EcoFlow Delta 2 ✅ (tested)
- EcoFlow Delta 2 + Delta 2 Max Extra Battery ✅ (tested)
- EcoFlow Delta 3 Max ✅ (tested)

**Likely compatible** (same API structure, untested)
- EcoFlow Delta 2 Max
- EcoFlow Delta Pro, with or without extra batteries (dedicated support since 2.6.1, built from a user's device data)
- EcoFlow Delta Max
- Delta 3
- Delta Mini
- River 2 / River 2 Pro / River 2 Max
- River Pro

**Not supported**
- PowerOcean, PowerStream — different API
- Delta (1st gen), River (1st gen) — different field names

> If you test EFStatus on a model not listed here, open an issue and let us know!

## Requirements

- macOS 13 or later
- Intel or Apple Silicon Mac
- An [EcoFlow developer account](https://developer.ecoflow.com) with an API key
- Xcode Command Line Tools (`xcode-select --install`) to build from source

## Download & run (no build required)

Get `EFStatus.app` from [Gumroad](https://bereto.gumroad.com/l/efstatus).

1. Download the app
2. Move it to your `/Applications` folder
3. Right-click → **Open** → **Open** (required once to bypass Gatekeeper on unsigned apps)
4. Enter your EcoFlow API credentials in the setup window

## Build from source

```bash
git clone https://github.com/bereto-dev/efstatus.git
cd efstatus
make
open EFStatus.app
```

Build on a Mac (`swiftc` + `lipo`). The first build downloads [Sparkle](https://sparkle-project.org) 2.10.0 into `vendor/` (checked against its SHA-256) for automatic updates. `make zip` packages `dist/EFStatus-<version>.zip`.

The first launch opens a setup window where you enter your EcoFlow API credentials. They're stored in your macOS Keychain and never sent anywhere other than the EcoFlow API. Versions before 2.4.0 kept them in `UserDefaults`; 2.4.0 moves them to the Keychain automatically on first launch. After installing a new version, macOS may ask once whether EFStatus can read its Keychain item; choose **Always Allow**.

## First launch security

Because the app isn't notarized (no Apple Developer account needed), macOS will block it the first time. Right-click → **Open** → **Open** to bypass Gatekeeper once.

## Settings

Right-click the menu bar icon → **Check for Updates…** / **Settings…** / **About EFStatus** / **Quit EFStatus**.

Settings also has **Check for updates automatically** (on by default).

## Credentials

Get your Access Key, Secret Key, and device serial number from [developer.ecoflow.com](https://developer.ecoflow.com).

To update credentials later: right-click the menu bar icon → **Settings…**

Save verifies the keys and SN against EcoFlow before dismissing the window.

## Notifications

EFStatus sends a macOS notification when:
- Input power drops to 0 W (confirmed: at least 10 seconds at 0 W, then double-checked against EcoFlow before alerting)
- Input power is restored after a confirmed outage
- The battery drops to 20% and 10% while discharging
- The battery reaches 100%
- The connection to your EcoFlow is lost (3 failed checks in a row) or comes back

Each power and battery alert can be toggled in Settings. Newer alerts replace older ones of the same kind instead of piling up in Notification Center. If you turn them on but macOS has denied notification permission (or a send fails), EFStatus tells you instead of failing silently.

## Updates

EFStatus checks for a new version once a day and asks before installing it, showing what's new with an **Install and Relaunch** button. You can also check any time from the right-click menu or About. Every update is signed, and the app only installs versions signed by the developer.

After an update, macOS may ask once whether EFStatus can read its Keychain item; choose **Always Allow**.

## Origin

Built by Roberto Pacheco because the EcoFlow Delta 2 doesn't surface consumption statistics in real time — and as his primary office backup power, he needed that data at a glance without picking up his phone.

## Help expand compatibility

If you have an EcoFlow device not listed above and want to help add support for it, run the diagnostic from the app: right-click the menu bar icon → **Copy Diagnostics**, then open a [GitHub issue](https://github.com/bereto-dev/efstatus/issues) and paste the output.

Copy Diagnostics includes:
- the app version, macOS version and Mac type
- what EFStatus shows: model, battery %, Wh, input, output, battery power and the time line
- the live feed's state, and the latest message of each type it received
- every raw field the device reports

**It includes the device serial number on purpose.** Access Key and Secret Key are not copied.

Or run it from the terminal (this script does **not** print credentials or the serial number):

```bash
curl -O https://raw.githubusercontent.com/bereto-dev/efstatus/main/diag.sh
chmod +x diag.sh
./diag.sh --access-key YOUR_KEY --secret-key YOUR_SECRET --serial YOUR_SERIAL
```

## Changelog

### 2.6.1 — DELTA Pro support, better diagnostics
- **DELTA Pro:** the popup names it DELTA PRO instead of DELTA 3, shows the remaining time during an outage instead of "Calculating…", and adds the MAIN / EXTRA row when an extra battery is attached
- **DELTA Pro:** input now shows only what comes in from outside (AC, solar). Before, what the extra battery feeds the main unit counted as input
- When the battery is idle (for example plugged in at the charge limit), the time line reads "On input power" instead of "Calculating…" or estimates of hundreds of hours from the battery's tiny idle current
- **Copy Diagnostics** now also includes the app version, what EFStatus shows, the live feed's state and a sample of its messages, so issues can be diagnosed from one paste

### 2.6.0 — Extra battery support, steadier live feed
- **Extra batteries:** with an extra battery on a DELTA 2 or DELTA 2 Max, the popup adds a MAIN / EXTRA row with each pack's percent and Wh, and the Wh next to the percentage is the total of all packs
- Time remaining and "Full in" now count every pack and use the batteries' own power, so they match reality (a DELTA 2 with an extra battery showed ~30 h left when the real figure was ~18 h)
- With an extra battery, input no longer counts what the extra battery feeds the main unit: it reads 0 W on battery, so the "No input power" alert works during a power cut
- If the live feed stays connected but stops sending data (seen after the Mac wakes up), EFStatus reconnects on its own instead of falling back to 60-second updates until relaunch
- Without an extra battery, every number is the same as before
- Thanks to [@andotsy](https://github.com/andotsy) for this release: the extra-battery support and the live-feed fix are their contribution ([#3](https://github.com/bereto-dev/efstatus/pull/3))

### 2.5.0 — Automatic updates
- EFStatus now updates itself: once a day it checks for a new version and shows what's new with an **Install and Relaunch** button
- Check any time from the right-click menu or About (**Check for Updates…**)
- Turn the daily check off in Settings (**Check for updates automatically**)
- Updates are signed, so the app only installs versions that really come from me

### 2.4.0 — Real-time MQTT, smarter alerts, Keychain
- **Real-time data now actually works:** the app was subscribed to an MQTT topic EcoFlow never publishes to, so it silently fell back to polling every 10 seconds. It now uses the correct feed and updates every couple of seconds
- Fixed REST requests being rejected ("signature is wrong"): EcoFlow now requires the query parameters in the request signature
- Far fewer API calls: no polling while MQTT is live, polling every 60s when the device is idle, and lightweight queries (~300 bytes instead of ~6.6 KB)
- "No input power" is double-checked against EcoFlow after 10 seconds at 0 W, and only fires if input was seen before
- New alerts: battery low (20% and 10%) and fully charged, each with its own toggle in Settings
- No more false "Lost connection" alerts after the Mac wakes up: EFStatus pauses on sleep and reconnects cleanly on wake; it only alerts after 3 failed checks in a row
- Notifications now show even with the popup open, and replace each other by type instead of stacking up
- Time remaining / time to full is smoothed so it no longer jumps with every watt
- API credentials moved from a plain-text preferences file to the macOS Keychain (migrated automatically)
- Lower CPU and energy use: the menu bar icon is drawn once, the popup only redraws while open, and all timers let macOS batch wakeups
- Minimum macOS is now 13 (matches the universal build)

### 2.3.0 — Color-coded battery bar, false-notification fix
- Progress bar now changes color by charge level: green (>50%), orange (21–50%), red (≤20%)
- Fixed false "No input power" notifications: MQTT merge now zeroes only the key-family present in the packet, so a solar-only update no longer clears AC input watts on DELTA 2
- Notification debounce refactored from a wall-clock timer to a consecutive-reading streak (2 readings required), which is faster to confirm real outages and more resilient to transient blips

### 2.2.1 — MQTT silence, setup validation, honest stale data
- MQTT watchdog actually fires after the first live message: 30s without PUBLISH falls back to REST; 90s without any inbound packet reconnects
- Lost connection / back online works on the MQTT path, not only REST `catch`
- Reconnect refreshes `/iot-open/sign/certification` instead of looping on a cached MQTT password
- Setup **Save & Connect** verifies keys and SN against EcoFlow before closing; bad or empty credentials stay on the window
- MQTT client: no force-unwrap on port, 1 MB receive cap, teardown-safe receive loop, malformed frames disconnect instead of growing the buffer
- Incremental MQTT updates treat omitted watt fields as 0 when a packet includes any input/output watts (no leftover charger watts)
- REST failures now surface HTTP status instead of looking healthy
- SOC displays `—` when the value is unknown, not a fake `0%`
- Notification permission / send failures are no longer silent if notification toggles are on
- Build number (`CFBundleVersion`) unstuck from `3`; marketing version is 2.2.1

### 2.2.0 — Smarter notifications and bolt icon in popup
- Replaced battery emoji in popup with the bolt SF Symbol used in the menu bar icon
- "No input power" notification now waits 7 seconds before firing — transient blips no longer trigger it
- New notification: input power restored after a confirmed outage
- Both notifications can be toggled individually in Settings

### 2.1.2 — Intel Macs and Gumroad
The downloadable app was Apple Silicon only, so it would not open on Intel Macs. It is now a universal build, and Check for Updates opens [Gumroad](https://bereto.gumroad.com/l/efstatus) instead of GitHub. GitHub is just for source if you want to build it yourself.

### v2.1.1
- Fixed popup getting stuck open when monitors are disconnected or rearranged
- Popup now closes on any click outside it (no need to click the icon again)

### v2.1.0
- New app icon and status bar icon using SF Symbol `bolt.fill`

### v2.0.0
- **Real-time data via MQTT** — EFStatus now connects to EcoFlow's live data feed (the same one used by the official app). Values update the moment your device reports a change instead of every 10 seconds.
- **Automatic reconnection** — if the MQTT connection drops, the app silently falls back to polling and reconnects in the background.
- **Fixed input reading bug** — input watts are now read from the correct fields, preventing the app from showing stale non-zero values after the charger is disconnected.
- **Delta 3 Max support** — device is detected automatically; model name (DELTA 2 / DELTA 3) shown in the popup.

### v1.4.0
- Added "Copy Diagnostics" menu option
- Added refresh button in popup with spin animation
- Fixed popup positioning (4px gap, centered on status bar icon)
- Fixed 0W input bug for Delta 2 (solar vs AC field conflict)

### v1.3.0
- Added About window with origin story and support links
- Added "Check for Updates" menu option
- Added version badge to README

### v1.2.0
- Improved popup design (dark card, color-coded watts)
- Fixed Cmd+V paste in setup window

### v1.1.0
- Fixed SOC accuracy using `bms_emsStatus.lcdShowSoc`
- Fixed UserDefaults crash on first launch

### v1.0.0
- Initial release

## Support

If you find EFStatus useful, you can buy me a coffee ☕

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-bereto-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/bereto)

---

Built with Swift + AppKit. Universal binary (x86_64 + arm64). No external dependencies.
