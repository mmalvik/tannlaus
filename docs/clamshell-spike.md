# Clamshell spike: manual test protocol

Branch `spike/clamshell-logging`. The spike build adds `Sources/Tannlaus/DockDiagnostics.swift`, which logs lid, display, power and wake details at every sleep, wake and dock change. It changes nothing: Bluetooth behaves exactly as in 1.0. Each log line also says what the planned 1.1 rule would do ("1.1 rule if Bluetooth was on: keep Bluetooth on (docked)" or "turn Bluetooth off (not docked)").

Not for release. Delete this file and `DockDiagnostics.swift` once 1.1 is designed.

## Setup

1. Quit any other Tannlaus (for example the Homebrew copy in /Applications), so only the spike build reacts to sleep.
2. `make app && open build/Tannlaus.app`. If macOS asks for Bluetooth permission again, click Allow.
3. Use **Terminal.app** for the log commands below. If it says "Could not open local log store: Operation not permitted", give Terminal.app Full Disk Access in System Settings > Privacy & Security.

After each test, save the log from the last few minutes, naming the file after the test:

```
log show --last 10m --style compact --predicate 'subsystem == "com.tannlaus.app" AND process == "Tannlaus"' > ~/Desktop/spike-T1.log
```

Also save macOS's own sleep/wake record, which shows wakes the app may not see:

```
pmset -g log | grep -E '^[0-9-]+ [0-9:]+ [+-][0-9]{4} (Sleep|Wake|DarkWake) ' | grep -v 'Wake Requests' | tail -30 > ~/Desktop/spike-T1-pmset.log
```

## T0: Launch (sandbox check)

Run the log command right after launching. Expect four lines: "Watching power source changes", "Watching display changes", "Watching lid changes", "Watching system power messages", and a `[Launch]` snapshot where "lid closed" and "closing lid sleeps" are `yes` or `no`, not `unreadable`.

Any "Could not…" or "failed (sandbox?)" line, or `unreadable`, is the answer to "does this work in the sandbox?". Send it back before running the rest.

Result (2026-11-16, MacBook on battery, no display): passed. All four watchers registered, and lid, power, displays and wake reasons were readable. Findings:
- The power source notification also fires about once a minute for battery level updates. The spike now logs only a change of source; 1.1 must do the same.
- `AppleClamshellCausesSleep` read `no` with the lid open, no display and on battery, so it can't be the docked signal. Use the display list.
- `make test` logs to the same subsystem from `swiftpm-testing-helper`; the commands above filter on `process == "Tannlaus"` to leave those out.

## Results

**T1 (2026-11-16, battery, no display, lid closed 77 s): passed.**
- Order of events at lid close: "Lid changed: closed" → system power "will sleep" (+7 ms) → NSWorkspace "will sleep" (+14 ms) → sleep handler finished (+0.14 s). macOS entered sleep about 5 s later.
- The lid event arrives *before* the sleep starts, and "last sleep reason" already reads `Clamshell Sleep` at that point. So at sleep time the app can tell that the lid caused the sleep.
- `AppleClamshellCausesSleep` read `yes` with the lid closed and `no` with it open. It only means something while the lid is closed.
- On wake: "Lid changed: open" (displays still asleep, wake type unreadable) → "will power on" → "Screens did wake" → "has powered on" → NSWorkspace "did wake", all within 0.3 s.
- Docked `no` throughout, so the 1.1 rule would turn Bluetooth off, the same as 1.0. No dark wakes during this short sleep.
- `0xe0034140` root domain messages around sleep are most likely "sleep/wake UUID changed"; noise.

**T2 (2026-11-16, charger, no display, lid closed 71 s): passed.**
- Plugging in the charger was logged once, as "Battery Power to AC Power", together with a lid message (lid open, closing lid sleeps `yes`). Lid close → will sleep → sleep handler finished in 0.1 s, the same order as T1. Docked `no`, so the rule turns Bluetooth off: the charger doesn't change the answer.
- **Dark wake right after sleep.** pmset shows `Clamshell Sleep` at 19:49:40, then a `DarkWake … due to … wifibt` 1 s later lasting 22 s, then `Maintenance Sleep`. The spike ran during it: a lid message arrived 5.6 s after will-sleep with closing lid sleeps `no` and Bluetooth `off`.
- IORegisterForSystemPower sent no "will power on" for the dark wake, and NSWorkspace sent no "did wake", so 1.0 correctly left Bluetooth off. But the app's callbacks do run during dark wakes, so a 1.1 dock-change handler would too.
- After the dark wake, "last sleep reason" changed to `Maintenance Sleep`. It is only reliable at sleep time, not at wake.
- `AppleClamshellCausesSleep` read `no` during the dark wake with the lid closed and no display. Another reason not to rely on it.

**T3 (2026-11-16, lid open, DELL U2717D and charger, HP 780M Bluetooth LE mouse, Apple menu > Sleep): 1.0 problem confirmed; 1.1 rule correct.**
- At will-sleep: docked `yes`, so the rule keeps Bluetooth on. 1.0 turned it off, and neither the Bluetooth mouse nor the keyboard could wake the Mac; the built-in keyboard did (wake reason `RTP.keyboard`).
- "Last sleep reason" read `Software Sleep` at will-sleep, so a menu sleep can be told apart from `Clamshell Sleep`.
- **The display list flickers.** Connecting the monitor logged added → removed 1.5 s later → added 0.9 s later. On wake the monitor was reported removed and added again 1 s later. 1.1 must wait for the display state to settle (a few seconds) before acting on a change, and must ignore changes during the wake itself, or it would briefly see "not docked".
- macOS entered sleep 30 s after will-sleep (5 s in T1 and T2). pmset names no app as slow to acknowledge (only `com.apple.audio.MacAudio` on later sleeps), so the spike is not the cause. The spike now logs its acknowledgement result to confirm.
- Dark wake from `wifibt` 1 s after sleep again, lasting 10 s.
- Open question: would this Bluetooth LE mouse wake the Mac even with Bluetooth on? Control test T3b answers it.

**T3b (control, Tannlaus quit, Bluetooth on during sleep): keyboard wakes, mouse doesn't.**
- The Bluetooth keyboard woke the Mac (pmset: `DarkWake … wifibt`, then `DarkWake to FullWake … due to HID Activity`). The HP 780M Bluetooth LE mouse did not, even with Bluetooth on.
- So keeping Bluetooth on fixes waking with the keyboard, but some Bluetooth LE mice can't wake a Mac at all. The README should say so.

**T4 (2026-11-16, clamshell: lid closed, DELL U2717D and charger, Apple menu > Sleep): 1.0 problem confirmed; 1.1 rule correct.**
- At will-sleep: lid closed `yes`, closing lid sleeps `no`, docked `yes`, so the rule keeps Bluetooth on. 1.0 turned it off; neither keyboard nor mouse could wake the Mac, only opening the lid.
- `AppleClamshellCausesSleep` read `no` here (lid closed, display) and `yes` in T1 (lid closed, no display), so in clamshell mode it does agree with the display list. It still read `no` during T2's dark wake, so it stays a secondary signal at most.
- The spike acknowledged sleep straight away (result `0x0`), yet macOS again entered sleep 30 s after will-sleep, as in T3. This is how a menu sleep behaves with the external display; it isn't caused by Tannlaus. Bluetooth is already off for those 30 s in 1.0.
- **Phantom display during wake.** At lid open, a display with no name, vendor `1970170734` and model `1986622068` (ASCII `unkn` / `virt`) appeared as *external* for about 0.4 s while the Dell was briefly removed; then only the built-in, then the Dell came back 1.3 s later. 1.1 must ignore displays like this (they look like macOS placeholders) and must wait for the display list to settle.

**T5 (2026-11-16, lid closed, DELL U2717D, charger unplugged): this Mac doesn't stay in clamshell mode on battery.**
- Unplugging the charger was logged as "AC Power to Battery Power". Closing the lid then reported closing lid sleeps `yes`, and the sleep reason was `Clamshell Sleep`, so the Mac went to sleep despite the monitor.
- At will-sleep the Dell was still listed, so docked `yes` and the rule keeps Bluetooth on. That's acceptable: the monitor is still connected, so you're at the desk, and the Bluetooth keyboard can wake it. Power still doesn't need to be part of the rule.
- The lid was opened 19.7 s after will-sleep, before macOS had actually entered sleep (pmset logs no sleep). "Did wake" still came exactly 30 s after will-sleep. **With the external display connected, macOS always took 30 s from will-sleep to sleep (T3, T4, T5).** If you change your mind in that window, 1.0 has already turned Bluetooth off and only restores it at "did wake", 30 s later.

**T6 + T7 (2026-11-16, clamshell, Dell and charger on separate cables, charger unplugged and plugged first both times).**

T6, undock:
- Charger and display changes arrived together (20:07:46.03), 0.2 s *before* will-sleep. With separate cables the unplug triggers the sleep, so it's known at sleep time (unlike the single-cable case in Bluesnooze PR 62).
- **The phantom display stays.** The Dell was renamed "Unknown Display", then removed, and the `unkn`/`virt` placeholder was added as an *external* display. It stayed listed for the whole sleep, until the lid was opened. At will-sleep the spike therefore said docked `yes`, which is **wrong**. With the placeholder filtered out the rule says not docked and turns Bluetooth off, which is right. Filtering it is required, not optional.
- Sleep reason `Clamshell Sleep`, entered 30 s after will-sleep.

T7, re-dock while asleep:
- Plugging in the charger caused `DarkWake … USB-C_plug`, then `DarkWake to FullWake … due to Notification` for 2 s, then `Notification Wake Back to Sleep`. The Mac then stayed in a dark wake for 23 s until the lid was opened.
- **NSWorkspace reported neither the wake nor the sleep.** System power did ("will power on", "has powered on", "will sleep" with reason `Notification Wake Back to Sleep`), and the power source callback fired (Battery to AC). So 1.0 never noticed the re-dock, and 1.1 must use system power messages or the power source callback to see it.
- **The monitor was not detected while asleep.** No display change arrived, the Dell stayed dark, and the display list still held only the placeholder. With separate cables, a display-based rule can't know the Mac was re-docked until it fully wakes, so Bluetooth stays off and the keyboard can't wake it. This would need a single-cable USB-C dock to retest (PR 62 suggests the display is seen during the brief wake there).
- Neither the mouse nor the keyboard woke the Mac (Bluetooth off, as expected with 1.0); opening the lid did.

**T8 (2026-11-16, no display, battery, lid closed; charger plugged in and out while asleep): Bluetooth stayed off; 1.1 must not treat these wakes as real wakes.**
- Plugging in the charger caused `DarkWake … USB-C_plug`, then `DarkWake to FullWake … due to Notification` for 4 s, with "Screens did wake", "will power on" and "has powered on", but **no NSWorkspace "did wake"**. Then `Notification Wake Back to Sleep`, a `wifibt` dark wake, and sleep.
- Unplugging the charger caused another dark wake (`USB-C_plug`, 6 s); the power source callback fired (AC to Battery).
- Bluetooth stayed off throughout, because 1.0 only restores on NSWorkspace "did wake". **1.1 must keep that: restore only on NSWorkspace "did wake", and use system power messages and power/display changes only to re-check the dock.** Otherwise a charger plugged in while the Mac is in a bag would turn Bluetooth on.
- macOS again took 30 s from will-sleep to sleep, this time with no display connected (T1 and T2 took 5 s). The spike acknowledged at once (`0x0`), so the delay isn't Tannlaus.

**T9 + T10 (2026-11-16, lid open, Dell and charger, Apple menu > Sleep; lid closed while asleep; then charger and Dell unplugged while asleep).**

T9, closing the lid on the sleeping Mac (display connected):
- **It caused a full wake**: pmset `Wake … due to … lid`, NSWorkspace "did wake", then NSWorkspace "will sleep" only 0.14 s later with `Clamshell Sleep`. 1.0 handled it (restore interrupted, Bluetooth recorded as on, turned off again).
- During that wake the Dell was reported removed (the same wake flicker as T3 and T4) and wasn't re-added before the Mac slept again. **At that will-sleep the display list said not docked although the Dell was still plugged in.** 1.1 can't wait for the list to settle inside the sleep handler, so it must use the last *settled* dock state at will-sleep, not the list at that instant.

T10, unplugging while asleep:
- No display event came for the physical unplug (the Dell was already gone from the list). The power source callback (AC to Battery) and lid messages arrived during a `wifibt` dark wake 11–14 s later, and the display list then correctly showed not docked.
- So undocking while asleep *can* be detected, but **1.1 must re-check the dock on any of these events (power, lid, display, system power), not only on display events.**
- If 1.1 had kept Bluetooth on, it would have to turn it off inside a dark wake lasting about 8 s. Switching takes 0.1–0.4 s, but 1.1 should hold a short sleep-prevention assertion while it switches. Check during implementation that this works in the sandbox.

## Tests

Start each test with Bluetooth on. "Wait" means at least 1 minute asleep unless stated.

| Test | Matrix row | Setup | Steps |
|---|---|---|---|
| T1 | 1 | No display, battery | Close the lid. Wait. Open it. |
| T2 | 2 | No display, charger only | Close the lid. Wait. Open it. |
| T3 | 4 | Lid open, monitor and charger connected, Bluetooth keyboard or mouse in use | Apple menu > Sleep. Wait. Try waking with the Bluetooth keyboard or mouse, then with the built-in keyboard. |
| T3b | 4 (control) | As T3, but **quit Tannlaus first** so Bluetooth stays on | Apple menu > Sleep. Wait. Try waking with the Bluetooth mouse, then the Bluetooth keyboard. If neither works with Bluetooth on, keeping it on in 1.1 won't help these devices. Reopen Tannlaus afterwards. |
| T4 | 5 | Clamshell: lid closed, monitor and charger connected | Apple menu > Sleep. Wait. Try waking with the Bluetooth mouse, then open the lid. |
| T5 | 6 | Lid closed, monitor connected, **no** charger (a monitor that doesn't supply power, or an HDMI adapter) | Does the Mac stay awake with the lid closed? If so, Apple menu > Sleep, wait, wake. |
| T6 | 8 | Clamshell as T4, awake, ideally on a single USB-C cable for monitor and power | Unplug the cable. Wait 2 minutes. Open the lid. |
| T7 | 9 | Mac asleep after T6, lid closed | Plug the cable back in. Wait 30 s. Click the Bluetooth mouse. If nothing happens, open the lid. |
| T8 | 10 | No display, Mac asleep with the lid closed | Plug in a charger. Wait 30 s. Unplug it. Wait 30 s. Open the lid. |
| T9 | 11 | No display, lid open | Apple menu > Sleep. Close the lid. Wait. Open it. |
| T10 | 12 | Lid open, monitor and charger connected | Apple menu > Sleep. Unplug monitor and charger. Wait. Open the lid. |
| T11 | 14 | Any | Use a Hot Corner set to "Put Display to Sleep". Wait 10 s. Move the mouse. |
| T12 | — | Awake, an iPad or Apple TV nearby | Turn on Sidecar or AirPlay display mirroring/extend, then turn it off. |
| T13 | — | Overnight: no display, lid closed, charger in | Leave it. In the morning, save the log with `--last 12h` and the pmset log. |

T11 (Hot Corner), T12 (Sidecar/AirPlay) and T13 (overnight) were skipped: every test showed that sleep handling starts only on will-sleep, T2–T10 already covered dark wakes, and 1.1 counts only physical external displays.

## What each test answers

- **T0:** whether lid, display, power and system power can be read and watched inside the sandbox with only the Bluetooth entitlement.
- **T1–T5:** whether "docked" (an external display in the `[NSWorkspace will sleep]` snapshot) is right in every plain sleep. T5 also shows whether clamshell mode works on battery on your Mac.
- **T6:** how long after `will sleep` the unplug is reported (look for "Power source changed" and "Display … removed" lines and their "s after will-sleep" times), and whether the `will sleep` snapshot still shows the display. This decides how the 1.1 re-check must work.
- **T7:** whether the re-dock wake reaches the app ("System power: will power on" / "has powered on", "NSWorkspace did wake"), how long the Mac stays awake before sleeping again, and in what order the display and power changes arrive. This decides whether 1.1 can turn Bluetooth on in time.
- **T8, T13:** whether chargers or maintenance cause brief or dark wakes ("System power: …" lines with no "NSWorkspace did wake", and "DarkWake" in the pmset log), and whether Bluetooth is on during them.
- **T9:** whether closing the lid on a sleeping Mac sends any event ("Lid changed").
- **T10:** whether an unplug while asleep is reported at all, and when.
- **T11:** that display-only sleep logs "Screens did sleep" but no `will sleep`.
- **T12:** whether Sidecar and AirPlay displays count as external (`docked: yes`). If they do, 1.1 must filter them out.

## Send back

The `spike-T*.log` and `spike-T*-pmset.log` files, plus one line per test on what happened physically (did the mouse wake it, did the Mac stay awake, how long it took).
