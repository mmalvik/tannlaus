# Tannlaus

Tannlaus is a small macOS menu bar app that turns Bluetooth off when your Mac goes to sleep and turns it back on when it wakes. Headphones, keyboards and other devices can't stay connected to, or reconnect to, a sleeping laptop, so your headset pairs with your phone instead.

- If Bluetooth was off before sleep, Tannlaus leaves it off after wake.
- Starting Tannlaus never changes your Bluetooth setting.
- No network access, no analytics, no data collection.

Requires macOS 14 (Sonoma) or later on Apple Silicon.

## Install

With [Homebrew](https://brew.sh):

```
brew tap mmalvik/tap
brew install --cask tannlaus
```

Or download `Tannlaus-X.Y.Z.dmg` from the [latest release](https://github.com/mmalvik/tannlaus/releases/latest), open it and drag Tannlaus to Applications.

The first time Tannlaus starts, macOS asks whether it may use Bluetooth. Click **Allow**. If you clicked Don't Allow, the menu shows "Bluetooth access denied" and an "Open Privacy Settings…" item where you can turn it on.

## Using it

Click the menu bar icon to see the current status and to change:

- **Launch at login**: start Tannlaus automatically when you log in.
- **Hide icon**: remove the icon from the menu bar. To get it back, open Tannlaus again from Applications.

## Why the name?

Bluetooth is named after the Danish king Harald Blåtann ("Bluetooth"). In Norwegian dialect, *tannlaus* means "toothless".

## Known limitations

- **Apple Watch unlock** needs Bluetooth at the lock screen, so it won't work right after wake until Bluetooth is back on.
- **Bluetooth can be slow to come back** on some Macs, sometimes 20–30 seconds after wake. This looks like a macOS issue; Tannlaus retries and logs the result.
- **Shutdown and restart** are not handled, only sleep. Bluetooth keeps whatever state it had.
- **Local builds** are ad-hoc signed, so macOS may ask for Bluetooth permission again after each rebuild. Released builds keep the permission across updates.

## Troubleshooting

Tannlaus logs every sleep, wake and Bluetooth change. In Console.app, filter on subsystem `com.tannlaus.app`, or run:

```
log stream --predicate 'subsystem == "com.tannlaus.app"' --level info
```

## Building

Needs Xcode (not just the Command Line Tools) on an Apple Silicon Mac.

```
make build   # compile
make test    # run unit tests
make app     # assemble and ad-hoc sign build/Tannlaus.app
open build/Tannlaus.app
```

The version comes from the newest released section in [CHANGELOG.md](CHANGELOG.md).

## Credits

Tannlaus is a clean-room rewrite inspired by [Bluesnooze](https://github.com/odlp/bluesnooze) by Oliver Peate (MIT licence).

## Licence

[MIT](LICENSE)
