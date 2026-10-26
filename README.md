# PocketDesk

[![CI](https://github.com/DamilolaDami/pocketdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/DamilolaDami/pocketdesk/actions/workflows/ci.yml)

Use your whole Mac from your phone, built for your thumb.

## Requirements

- Xcode 26+, iOS 26 / macOS 26 deployment targets
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Getting started

```bash
xcodegen            # generates PocketDesk.xcodeproj
open PocketDesk.xcodeproj
```

Run the shared logic tests without Xcode:

```bash
cd Packages/PocketDeskKit && swift test
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works and
[CONTRIBUTING.md](CONTRIBUTING.md) for building, signing and testing.

## Keep your Mac available

Open PocketDesk's Mac menu bar panel and use **Keep this Mac available**:

- **While streaming** prevents idle system sleep during a screen-sharing session.
- **Keep Available for…** starts a 15-minute to 8-hour timer, including before a phone connects.
- **Allow on battery** opts into battery use. Otherwise, requests wait for external power;
  the timer still counts down while waiting.
- **End Now** cancels the timer and stops keeping current sessions awake. A new session,
  a new timer, or turning While streaming off and on can request it again.

These options start off. Preferences survive relaunch; timers do not. A cup appears beside
the menu bar icon while PocketDesk holds a sleep assertion. The display can still turn off,
and manual Sleep, closing the lid, shutdown, and low-battery sleep remain under macOS control.
This does not wake a sleeping or shut-down Mac. Timers also end when the Mac goes to sleep.

## Organize Mac files from your phone

On the Mac, open the gear menu → **Share Files with Phones** and share a folder. Under
**Allow File Changes**, enable the folders you want to organize remotely. Existing shares
remain read-only until you opt in, and turning sharing off also removes write access.

In the phone's Mac Files browser, use **New Folder**, or touch and hold an item for **Rename**,
**Move…**, or **Move to Trash…**. Moves stay within the same shared root and volume.
If a name already exists, choose another name or cancel; PocketDesk never replaces it.
Trash asks for confirmation, and items can be recovered from the Mac's Trash.

Changed items must be listed again before they can be edited. Links can be browsed where
already allowed, but cannot be used for file changes. Each attempt refreshes the folder;
a disconnected or unconfirmed operation is never retried automatically. These controls
require protocol 22 on both the phone and Mac, so update them together.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE).
