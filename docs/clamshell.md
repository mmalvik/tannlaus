# Sleeping at a desk (clamshell and docked)

Tannlaus 1.0 turned Bluetooth off at every sleep. At a desk, with the lid closed next to a monitor (clamshell mode) or open beside it, that left a Bluetooth keyboard unable to wake the Mac: only the lid or the built-in keyboard could. Now Tannlaus keeps Bluetooth on while a Mac laptop sleeps docked.

## The rule

- **At sleep:** if Bluetooth is off, it stays off through sleep and wake. If it is on, it is recorded as on, then kept on if the Mac is docked and turned off if not, as 1.0 does. Recording it as on in both cases keeps the wake restore and the undock rule working.
- **Docked** means at least one physical external display in the last *settled* display list: the list once it has had no display change for 3 seconds. The built-in display, macOS's placeholder display and displays without a vendor ID don't count.
- **Laptops only.** A desktop Mac (mini, Studio, Pro) always has a monitor, so it would always count as docked and Bluetooth would never go off. On a Mac without a built-in battery the rule is off and the menu item is hidden; it behaves as 1.0.
- **While asleep:** every display change, power source change, lid change and system power message re-checks the dock. Display changes settle first; the other events read the display list again straight away unless a display change is settling, because an undock while asleep can arrive with no display event. Docked makes sure Bluetooth is on; not docked turns it off. Changes are read back and retried a few times, then given up.
- **Not during a real wake:** a change found after a lid, power or system power event waits 1 second first. On a full wake those events come up to 0.45 s before NSWorkspace "did wake", and acting on them would turn Bluetooth off just before the wake restore turns it on again.
- **Staying awake for it:** while asleep and a display change is settling, a re-check is waiting, or a change is running or waiting to retry, Tannlaus holds a sleep assertion (renewed at every step, since it times out after 30 s), and it holds back its system sleep acknowledgement until all of that is done.
- **On wake:** Bluetooth is restored only on NSWorkspace "did wake", never on the brief wakes that only system power reports.
- **Setting:** "Keep Bluetooth on when docked" in the menu, on by default. When off, Tannlaus behaves exactly as 1.0.

The code is in `Sources/TannlausCore` (`Display.swift`, `DockTracker.swift`, `PowerCoordinator.swift`), and `ScenarioTests.swift` replays every observed sequence below.

## What macOS does

Measured on 2026-11-16 on an Apple Silicon MacBook with macOS 27, a Dell U2717D monitor and a charger on separate cables, a Bluetooth keyboard and an HP 780M Bluetooth LE mouse.

- **The display list flickers.** Connecting the monitor reported it added, removed 1.5 s later, then added again 0.9 s after that. On every wake it was removed and added back 0.6–1.2 s later. Hence the 3-second settle time.
- **A placeholder display appears.** It has vendor 1970170734 (ASCII `unkn`) and model 1986622068 (`virt`), and `CGDisplayIsBuiltin` calls it external. It showed up for about 0.4 s during a wake, and after the monitor was unplugged with the lid closed it stayed listed for the whole sleep. Counting it made an undocked Mac look docked.
- **Undocking triggers the sleep.** With the lid closed, unplugging charger and monitor reported both changes 0.2 s before will-sleep. The settled state at will-sleep still said docked, so Bluetooth stays on for 3 seconds, until the list settles; Tannlaus holds back its sleep acknowledgement until then, so the Mac can't sleep first.
- **Undocking while asleep may only show up as power and lid messages** in a dark wake, with no display event. In every logged event the display list matched the last display event, so reading it then is as good as a settle.
- **Closing the lid on a sleeping docked Mac fully wakes it.** NSWorkspace sent "did wake" and a new "will sleep" 0.14 s later, before the monitor was added back. Using the settled state, Tannlaus keeps Bluetooth on at that will-sleep, but macOS didn't list the monitor again before sleeping, so the list then settles as not docked and Bluetooth goes off. The result is 1.0's behaviour.
- **Brief and dark wakes aren't wakes.** Plugging in a charger while asleep caused a 2–4 s wake with system power "will power on" and "has powered on", but no NSWorkspace "did wake". There were also dark wakes of 8–22 s (`wifibt`) about a second after sleep. Restoring on these would turn Bluetooth on in a bag.
- **Power source notifications** fire about once a minute for battery level updates; only a change of source counts.
- **`AppleClamshellCausesSleep` can't be used.** It is `no` whenever the lid is open, and read `no` during a dark wake with the lid closed and no display.
- **The lid event arrives before will-sleep**, and "Last Sleep Reason" (`Clamshell Sleep`, `Software Sleep`) is right at will-sleep but is overwritten by later dark wakes. Neither is needed for the rule.
- **macOS takes 30 s from will-sleep to sleep** with an external display connected, and sometimes without. Tannlaus acknowledges at once; the delay is macOS.
- **This Mac doesn't stay in clamshell mode on battery.** Closing the lid with the monitor connected but no charger put it to sleep. The monitor is still listed, so it counts as docked.
- **Sandbox:** the power source, display, lid and system power registrations and the sleep assertion all work with only the Bluetooth entitlement.

## Known limits

- **Re-docking while asleep isn't seen with separate cables.** Plugging the charger back in wakes the Mac briefly, but the monitor isn't listed until a full wake, so Bluetooth stays off and you have to open the lid. A single-cable USB-C dock is untested; if macOS lists the monitor during that brief wake, Tannlaus asks macOS to stay awake for the 3-second settle and then turns Bluetooth on.
- **Closing the lid on a Mac already asleep at a desk** ends with Bluetooth off (see above).
- **Some Bluetooth LE mice can't wake a Mac**, even with Bluetooth on. The HP 780M couldn't; the Bluetooth keyboard could.
- **Sleep assertions are suggestions.** On battery, macOS may end a dark wake while Tannlaus is still settling or switching. The change then finishes in the next wake.
- **Untested:** Sidecar, AirPlay and other virtual displays, and single-cable docks. Only displays with a vendor ID count, but a virtual display that reports one would count as docked.
- **Display-only sleep** (a Hot Corner set to "Put Display to Sleep") isn't sleep; Tannlaus does nothing.

## Raw data

The test protocol (T0–T13), its results and the logging build are on branch [`spike/clamshell-logging`](https://github.com/mmalvik/tannlaus/tree/spike/clamshell-logging) in `docs/clamshell-spike.md` and `Sources/Tannlaus/DockDiagnostics.swift`.
