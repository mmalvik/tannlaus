## What and why

<!-- What changed, and why. Link the issue if there is one. -->

## Checklist

- [ ] User-visible change: entry under `## [Unreleased]` in `CHANGELOG.md`. Otherwise: the `skip-changelog` label.
- [ ] `make build` and `make test` pass.
- [ ] Logic changes have unit tests; sleep, wake or dock changes have a replayed scenario in `ScenarioTests.swift`.

## Manual checks

<!-- Which checks in docs/testing.md you ran (by number), and which still need running. "None needed" is fine for docs or CI changes. -->

- Ran:
- Still needed:

## Behaviour that must not change

<!-- See the list in AGENTS.md. -->

- [ ] This PR doesn't touch anything under "Behaviour that must not change" in `AGENTS.md`.
- [ ] It does, and this was agreed first: <!-- which item, and where it was agreed -->
