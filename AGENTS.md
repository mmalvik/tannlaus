# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project

Tannlaus is a macOS menu bar app (Swift, AppKit) that turns Bluetooth off when the Mac sleeps and restores it on wake. `REQUIREMENTS.md` is the authoritative spec. Read it before making changes, and don't contradict it without asking.

Tannlaus is a clean-room rewrite inspired by Bluesnooze. Never copy upstream code or structure without keeping its MIT notice. `docs/phase-0.md` records the feasibility spike behind FR9.

## Commands

- `make build` — build the app
- `make test` — run unit tests
- `make app` — assemble and ad-hoc sign `Tannlaus.app` for local testing

Always run `make build` and `make test` before declaring a task done.

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
