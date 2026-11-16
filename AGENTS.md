# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project

Tannlaus is a macOS menu bar app (Swift, AppKit) that turns Bluetooth off when the Mac sleeps and restores it on wake. The README describes it for users; this file holds what contributors must not break.

Tannlaus is a clean-room rewrite inspired by Bluesnooze (MIT). Never copy upstream code or structure without keeping its MIT notice.

## Behaviour that must not change

Ask before changing any of these.

- On sleep, record whether Bluetooth is on. If it is on and the Mac is docked, keep it on; otherwise turn it off. Either way it is recorded as on. The sleep handler finishes any change and reads it back before returning, so the Mac can't sleep first.
- Docked means at least one physical external display in the last *settled* display list (unchanged for a few seconds), never the list at that instant. macOS's placeholder display (vendor `unkn`, model `virt`) never counts. Don't use `AppleClamshellCausesSleep`. The measurements behind this are in `docs/clamshell.md`.
- While asleep with Bluetooth recorded as on, re-check docked on every display change, power source change (a change of source, not a battery level update), lid change and system power message: docked makes sure Bluetooth is on, not docked turns it off. Hold a sleep assertion while switching, and acknowledge system power "will sleep" only once a running Bluetooth call has finished.
- On wake, turn Bluetooth on only if it was on before sleep, and only on NSWorkspace "did wake". Brief and dark wakes that only system power reports (a charger plugged in) re-check the dock and never restore Bluetooth. If no sleep was recorded, change nothing.
- "Keep Bluetooth on when docked" is on by default. When it is off, sleep and wake behave exactly as in 1.0: always off at sleep, no re-checks while asleep.
- Decisions live in `TannlausCore` behind `BluetoothController` and `DockEnvironment`; the IOKit, CoreGraphics and AppKit adapters in `Sources/Tannlaus` stay free of logic.
- Launching the app never changes Bluetooth.
- After every change, read the state back and retry a few times with backoff, then give up and log it. Never loop. A new sleep, a wake or a newer dock decision cancels pending retries.
- Shutdown and logout are not handled: the off state would survive the restart.
- Never call the private IOBluetooth functions without Bluetooth permission (`CBManager.authorization`). Ask for permission at launch, never at sleep. Without permission, skip sleep and wake, show "Bluetooth access denied" in the menu, and show the icon even if it is hidden.
- Private calls run off the main thread with a timeout, and new calls are refused while one is stuck. The reasons are in `SystemBluetoothController.swift`.
- Hiding the icon removes the status item entirely; opening the app again shows it.
- Sandboxed, with only the `com.apple.security.device.bluetooth` entitlement. No network access, analytics or in-app updater; Homebrew handles updates.
- Apple Silicon only, macOS 14 or later.

## Commands

- `make build` — build the app
- `make test` — run unit tests
- `make app` — assemble and ad-hoc sign `Tannlaus.app` for local testing

Always run `make build` and `make test` before declaring a task done. Logic changes need unit tests, and changes to sleep, wake or dock handling need a replayed scenario in `ScenarioTests.swift`. Unit tests can't cover real sleep, permission dialogs or installing; tell the user which checks in `docs/testing.md` a change needs.

## Changelog (required)

Every user-visible change adds an entry to `CHANGELOG.md` under `## [Unreleased]`, in the same commit as the change.

- Use the Keep a Changelog categories: Added, Changed, Deprecated, Removed, Fixed, Security.
- Write each entry for users, not developers: what changed for them, in one line.
- Changes with no user-visible effect (CI, refactoring, tests, docs) need no entry; the PR gets the `skip-changelog` label instead.
- Never edit an already-released version section.
- Never change the version anywhere else: CHANGELOG.md is the only source of the version number.
- Only cut a release (rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`) when explicitly asked.

## Rules

- No third-party dependencies of any kind. Ask first if one seems necessary.
- Keep Bluetooth access behind the `BluetoothController` protocol; logic must stay testable with a fake.
- Log through `os.Logger` with subsystem `com.tannlaus.app`.
- Never commit secrets, certificates or tokens. Signing happens only in CI.
- Don't modify `.github/workflows/` signing or release steps without being asked.
- All work goes through pull requests; `main` is protected and accepts squash merges only.
- UI text, docs, comments and commit messages in English.
