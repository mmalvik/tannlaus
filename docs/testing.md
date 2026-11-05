# Manual testing

`make test` covers the sleep/wake logic with a fake Bluetooth controller. These checks cover what unit tests can't: real sleep, permission dialogs and installing. Run the relevant ones for a change, and all of them before a release.

Build and open a local copy with `make app && open build/Tannlaus.app`. Follow the logs with:

```
log stream --predicate 'subsystem == "com.tannlaus.app"' --level info
```

## Sleep and wake

1. Bluetooth on, then `pmset sleepnow`, then wake: Bluetooth comes back on.
2. Bluetooth off, then sleep and wake: Bluetooth stays off.
3. Headset connected, close the lid, turn the headset off and on again away from the Mac: it pairs with the phone, not the Mac.

## Permission

4. Reset permission with `tccutil reset BluetoothAlways com.tannlaus.app`, open the app and click Don't Allow: the app keeps running, the menu shows "Bluetooth access denied", and sleep and wake leave Bluetooth untouched. Allow it in System Settings: the app works again without a relaunch.

## Menu

5. Hide the icon, then open the app again: the icon is back and Quit is reachable.
6. Turn on Launch at login, then log out and in: the app is running and Bluetooth is unchanged.

## Install (release builds)

7. `brew tap mmalvik/tap && brew install --cask tannlaus` on a clean Mac: the app opens with no Gatekeeper warning.
8. `brew upgrade` to a newer release: Bluetooth permission and Launch at login are still in place.
9. `brew uninstall --zap --cask tannlaus`: the app quits and is removed, and its container and preferences are gone.

Each check should leave log entries in Console.app.
