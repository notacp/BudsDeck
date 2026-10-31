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

Requires **macOS 26 or later on an Apple Silicon Mac**, plus the **Xcode 26 command-line tools** to build (older tools lack the Liquid Glass APIs). Reports for other models are welcome; open an issue.

## Install

There is no signed download yet, so build it from source. You need the Xcode Command Line Tools (`xcode-select --install`):

```sh
git clone https://github.com/notacp/BudsDeck.git
cd BudsDeck
./build.sh        # builds, runs a self-test, installs to ~/Applications
open ~/Applications/BudsDeck.app
```

Allow Bluetooth access when macOS asks. Tick **Open at login** in the panel to start it automatically. To update, `git pull` and run `./build.sh` again; it restarts the app.

## Good to know

- **Wear at least one bud to change noise modes.** The firmware rejects mode changes while both buds are out of your ears. BudsDeck reads the wear sensors and shows a notice instead.
- **Wear status is polled.** The buds don't announce when you put them in, so BudsDeck checks every 3 seconds while the panel is open and every minute otherwise.
- **One controller at a time.** The buds accept a single control connection. Quit BudsDeck before using another tool that talks to them.
- **ANC level mapping** follows the bit order a Buds 4 / Buds Pro 3 implementation verified on hardware (Max, Moderate, Mild, Adaptive), and it matches Buds 3 behaviour. It has not been checked by ear on Buds 3. If a level sounds wrong, adjust `ancVariants` in `BudsDeck.swift`.
- **Custom EQ edits the selected slot.** If you made custom EQs in HeyMelody, BudsDeck edits whichever one is active. Unnamed flat "Custom" placeholder slots may merge into one; named slots are kept.
- **Rebuilds and Bluetooth permission:** ad-hoc builds re-ask for Bluetooth permission after every rebuild. To avoid this, put your own signing identity in `local.env` (see `build.sh`).

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
