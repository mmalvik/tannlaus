# Testing

Tannlaus is tested almost entirely by `make test`. All decisions live in `TannlausCore` behind three seams that tests replace with fakes:

- `BluetoothController`: Bluetooth power and permission (`FakeBluetoothController`).
- `DockEnvironment`: the display list, power source and sleep assertions (`FakeDockEnvironment`).
- `Scheduler`: timers, background work and pauses (`FakeScheduler`, with a fake clock).

The adapters in `Sources/Tannlaus` (CoreBluetooth, IOKit, CoreGraphics, AppKit) only read values and pass events on, so the manual checks below are the only things unit tests can't reach.

## What the tests cover

- **`PowerCoordinatorTests`:** sleep and wake as in 1.0 (not docked): recording, restoring, read-back, retries with backoff, giving up, background restore, interrupted restores and permission.
- **`DockRuleTests`:** "Keep Bluetooth on when docked": the rule at sleep, the setting, desktop Macs, the settled state at will-sleep, re-checks while asleep (with and without a display event), brief wakes that must not restore, sleep assertions, retries and cancellation, permission and the delayed system sleep acknowledgement.
- **`DisplayTests`:** display classification with the values recorded on real hardware (built-in 1552/41041, Dell 4268/16619, macOS's placeholder `unkn`/`virt`), the settle timer and the power source filter.
- **`ScenarioTests`:** the event sequences recorded by the clamshell spike (T1–T10), replayed with their real order and timing, plus T10's unplug on its own. Each test checks Bluetooth at the points where it matters and that nothing is left pending.

When macOS behaves in a new way, record it (see "Re-running the spike") and add it as a scenario. When you change the logic, the scenarios show which recorded situation it breaks.

## Manual smoke checks

Build and open a local copy with `make app && open build/Tannlaus.app`, and follow the logs with:

```
log stream --predicate 'subsystem == "com.tannlaus.app"' --level info
```

`--level info` adds the lines that can repeat many times per sleep (power and lid repeats, dock checks that change nothing). Every sleep, wake, Bluetooth change and dock decision that changes something is logged at notice level and stays in the system log, so `log show --predicate 'subsystem == "com.tannlaus.app"' --last 10m` finds it afterwards without `--info`.

Run the relevant checks for a change, and all of them before a release.

### Sleep

1. No monitor, Bluetooth on: `pmset sleepnow`, then wake. Bluetooth comes back on. Repeat by closing the lid for a minute: Bluetooth is off while asleep and back on after wake.
2. Bluetooth off: sleep and wake. It stays off.
3. No monitor, headset connected: close the lid, then turn the headset off and on again away from the Mac. It pairs with the phone, not the Mac.
4. Monitor connected, Bluetooth keyboard: Apple menu > Sleep, wait a minute, press a key on the Bluetooth keyboard. The Mac wakes. The log shows a "Dock check (will sleep): docked …; keeping Bluetooth on" line.
5. As 4 with "Keep Bluetooth on when docked" turned off: the Bluetooth keyboard can't wake the Mac, and Bluetooth is back on after wake.

### Permission

6. Reset permission with `tccutil reset BluetoothAlways com.tannlaus.app`, open the app and click Don't Allow: the app keeps running, the menu shows "Bluetooth access denied", and sleep and wake leave Bluetooth untouched. Allow it in System Settings: the app works again without a relaunch.

### Menu

7. Hide the icon, then open the app again: the icon is back and Quit is reachable.
8. Turn on Launch at login, then log out and in: the app is running and Bluetooth is unchanged.
9. Turn "Keep Bluetooth on when docked" off, quit and reopen: it is still off. On a desktop Mac, if you have one, the item isn't in the menu.

### Install (release builds)

10. `brew install --cask mmalvik/tap/tannlaus` on a clean Mac: the app opens with no Gatekeeper warning.
11. `brew upgrade` to a newer release: Bluetooth permission, Launch at login and the docked setting are still in place.
12. `brew uninstall --zap --cask tannlaus`: the app quits and is removed, and its container and preferences are gone.

## Re-running the spike

The clamshell spike measured how macOS reports sleep, wake, lid, display and power events. To measure again (a new macOS version, a single-cable dock, Sidecar), check out branch `spike/clamshell-logging` and follow `docs/clamshell-spike.md` there: it builds a logging-only Tannlaus 1.0 and lists the tests T0–T13 and the log commands. Its results are summarised in [clamshell.md](clamshell.md).
