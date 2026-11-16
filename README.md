# Tannlaus

Tannlaus is a small macOS menu bar app that turns Bluetooth off when your Mac goes to sleep and turns it back on when it wakes. Headphones, keyboards and other devices can't stay connected to, or reconnect to, a sleeping laptop, so your headset pairs with your phone instead.

- If Bluetooth was off before sleep, Tannlaus leaves it off after wake.
- On a Mac laptop at a desk, with an external display connected, Bluetooth stays on while the Mac sleeps, so your Bluetooth keyboard can wake it. Unplug the display and Bluetooth goes off.
- Starting Tannlaus never changes your Bluetooth setting.
- No network access, no analytics, no data collection.

Requires macOS 14 (Sonoma) or later on Apple Silicon.

## Install

With [Homebrew](https://brew.sh):

```
brew install --cask mmalvik/tap/tannlaus
```

Using the full name adds the tap and tells Homebrew to trust the cask, which Homebrew requires for apps outside its official collection.

Or download `Tannlaus-X.Y.Z.dmg` from the [latest release](https://github.com/mmalvik/tannlaus/releases/latest), open it and drag Tannlaus to Applications.

The first time Tannlaus starts, macOS asks whether it may use Bluetooth. Click **Allow**. If you clicked Don't Allow, the menu shows "Bluetooth access denied" and an "Open Privacy Settings…" item where you can turn it on.

## Using it

Click the menu bar icon to see the current status and to change:

- **Keep Bluetooth on when docked** (laptops only, on by default): while the Mac sleeps with an external monitor connected, lid open or closed, Bluetooth stays on. Turn it off to have Bluetooth off at every sleep. Desktop Macs always have a monitor, so there Bluetooth goes off at every sleep and the item isn't shown.
- **Launch at login**: start Tannlaus automatically when you log in.
- **Hide icon**: remove the icon from the menu bar. To get it back, open Tannlaus again from Applications.

## Why the name?

Bluetooth is named after the Danish king Harald Blåtann ("Bluetooth"). In Norwegian dialect, *tannlaus* means "toothless".

## Known limitations

- **Apple Watch unlock** needs Bluetooth at the lock screen, so it won't work right after wake until Bluetooth is back on.
- **Bluetooth can be slow to come back** on some Macs, sometimes 20–30 seconds after wake. This looks like a macOS issue; Tannlaus retries and logs the result.
- **Shutdown and restart** are not handled, only sleep. Bluetooth keeps whatever state it had.
- **Re-docking while asleep** isn't noticed when the monitor and charger use separate cables: macOS doesn't report the monitor until the Mac fully wakes, so Bluetooth stays off and you need to open the lid. Single-cable USB-C docks are untested.
- **Closing the lid on a Mac that is already asleep at a desk** wakes it briefly, and macOS drops the monitor during that wake, so Bluetooth ends up off.
- **Some Bluetooth LE mice can't wake a Mac**, even with Bluetooth on. A Bluetooth keyboard can.
- **Display sleep** (for example a Hot Corner set to "Put Display to Sleep") is not sleep, so Tannlaus does nothing.
- **Sidecar, AirPlay and other virtual displays** are untested as "docked".
- **Local builds** are ad-hoc signed, so macOS may ask for Bluetooth permission again after each rebuild. Released builds keep the permission across updates.

## Troubleshooting

Tannlaus logs every sleep, wake and Bluetooth change, and one "Dock check" line for each docked decision. In Console.app, filter on subsystem `com.tannlaus.app`, or run:

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
