# BudsDeck

A Liquid Glass menu bar panel for **OnePlus, OPPO and realme earbuds** on macOS: noise control, EQ and battery, without a phone.

```
╭──────────────────────────────────╮
│ 🎧 OnePlus Buds 3                 │
│ ( L 100% ) ( R 100% )             │
│   (⊘)        (●)        (👂)      │
│   Off   Noise Cancelling  Transparency
│ Level  [ Adaptive ⌃⌄ ]            │
│ ▸ Equalizer              Balanced │
╰──────────────────────────────────╯
```

These earbuds are normally configured through OnePlus's HeyMelody app on Android. BudsDeck speaks the same Bluetooth protocol directly from your Mac.

## Features

- **Noise control:** Off, Noise Cancelling and Transparency, plus ANC levels (Adaptive, Max, Moderate, Mild)
- **Equalizer:** Balanced, Bold, Serenade and Bass presets, plus a 6-band custom EQ (62 Hz–16 kHz, ±6 dB) saved on the buds
- **Battery** for each bud and the case, with a charging indicator. The buds report the case only while docked or just after the lid opens, so BudsDeck shows the most recent case reading
- Works for whichever HeyMelody earbuds are currently connected. Nothing is tied to a specific address.

## Compatibility

| Device | Status |
|---|---|
| OnePlus Buds 3 | Tested: noise modes, ANC levels, EQ presets, custom EQ, battery |
| Other OnePlus / OPPO Enco / realme buds | Should connect (same protocol); mode bits and EQ presets can differ per model |

Requires **macOS 26 or later** (Apple Silicon or Intel). Reports for other models are welcome; open an issue.

## Install

**Download:** [BudsDeck.dmg](https://github.com/notacp/BudsDeck/releases/latest/download/BudsDeck.dmg) (500 KB, Apple Silicon and Intel). Open it and drag **BudsDeck** into **Applications**.

**First launch:** BudsDeck isn't notarized by Apple yet, so macOS blocks it the first time:

1. Open BudsDeck from Applications. macOS says it "could not verify" the app; click **Done**.
2. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to BudsDeck, then confirm with your password.
3. Allow **Bluetooth** access when asked.

Prefer Terminal? After dragging BudsDeck to Applications, this does the same as steps 1–2 by removing the download quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/BudsDeck.app
```

You only do this once. Tick **Open at login** in the panel to start it automatically.

### Build from source

You need the **Xcode 26 command-line tools** (`xcode-select --install`); older tools lack the Liquid Glass APIs.

```sh
git clone https://github.com/notacp/BudsDeck.git
cd BudsDeck
./build.sh        # builds, runs a self-test, installs to ~/Applications
open ~/Applications/BudsDeck.app
```

To update, `git pull` and run `./build.sh` again; it restarts the app. `./build.sh --dmg` makes the release DMG.

## Good to know

- **Wear at least one bud to change noise modes.** The firmware rejects mode changes while both buds are out of your ears. BudsDeck reads the wear sensors and shows a notice instead.
- **Wear status is polled.** The buds don't announce when you put them in, so BudsDeck checks every 3 seconds while the panel is open and every minute otherwise.
- **One controller at a time.** The buds accept a single control connection. Quit BudsDeck before using another tool that talks to them.
- **ANC level mapping** follows the bit order a Buds 4 / Buds Pro 3 implementation verified on hardware (Max, Moderate, Mild, Adaptive), and it matches Buds 3 behaviour. It has not been checked by ear on Buds 3. If a level sounds wrong, adjust `ancVariants` in `BudsDeck.swift`.
- **Custom EQ edits the selected slot.** If you made custom EQs in HeyMelody, BudsDeck edits whichever one is active. Unnamed flat "Custom" placeholder slots may merge into one; named slots are kept.
- **Rebuilds and Bluetooth permission:** ad-hoc builds re-ask for Bluetooth permission after every rebuild. To avoid this, put your own signing identity in `local.env` (see `build.sh`).

## Privacy

BudsDeck sends a few anonymous events so the maintainer can see roughly how many people use it, and whether it works for them. Usage events go out **at most once per day**; a crash report goes out once per crash (at most 3 per launch):

| Event | When | Why |
|---|---|---|
| `app_launched` | the app runs | count installs, including ones where the earbuds never connect |
| `app_active` | your earbuds connect | count working installs, by model |
| `connect_failed` | connecting fails, with a reason code (`no_compatible_device`, `permission_denied`, `timeout`, `open_failed`) | find what's broken for whom |
| `$exception` | on launch, if BudsDeck crashed since last time | fix crashes: crash type (e.g. `EXC_BREAKPOINT`) and **BudsDeck's own function names** from the crash report only, no file paths or memory contents |

| Sent | Not sent |
|---|---|
| A random install ID created on first launch | Your name, email or Apple ID |
| App version, macOS version, Apple Silicon or Intel | Your IP address (discarded by the analytics project) |
| The earbuds' model, e.g. "OnePlus Buds 3", picked from a fixed list of known models (otherwise "other"), and the model code the earbuds report (e.g. `063C14`, identical for every unit of that model) | Your earbuds' Bluetooth name if you renamed them, Bluetooth addresses, settings, listening activity |

Turn it off any time: gear menu in the panel → **Share Anonymous Usage Stats**. The code is in `Telemetry` in [`BudsDeck.swift`](BudsDeck.swift).

**Report a Problem…** (gear menu) opens a GitHub issue pre-filled with your BudsDeck and macOS versions, earbuds model, last connection problem and last crash summary. You see all of it in your browser and choose whether to submit it.

**Update check:** once a day BudsDeck asks GitHub's public API for the latest release and shows a banner when a newer version exists. That request sends nothing about you (GitHub sees an ordinary web request) and is independent of the usage-stats setting.

## How it works

The buds expose a vendor serial service ("enco link", RFCOMM, UUID `0000079a-d102-11e1-9b23-00025b00a5a5`). BudsDeck opens it with IOBluetooth and sends small framed commands. The format is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

Everything is in one Swift file, [`BudsDeck.swift`](BudsDeck.swift): the protocol codec, the Bluetooth link and the SwiftUI panel.

## Credits

Prior open-source work on this protocol family:
[omarchy-headphones `oppo-bridge`](https://github.com/ncr/omarchy-headphones) (Linux, frame format),
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (OPPO Enco support),
[OnePlus Buds Windows Companion](https://github.com/Thomaspatrick14/Oneplus-buds-Win-Companion) (EQ preset IDs).

## Disclaimer

BudsDeck is an independent project. It is not affiliated with, endorsed by or supported by OnePlus, OPPO or realme. Product names are trademarks of their owners and are used here only to describe compatibility. Commands are sent to your earbuds at your own risk. Everything BudsDeck changes can also be changed back in the official app.

## License

[MIT](LICENSE)
