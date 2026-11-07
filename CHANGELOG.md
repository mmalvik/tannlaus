# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-07
### Added

- The menu shows "Not working: unsupported macOS version", and the icon stays visible, if a macOS update stops Tannlaus from switching Bluetooth.

### Fixed

- Bluetooth you turned off yourself no longer comes back on at the next wake after Bluetooth access was briefly revoked.
- Bluetooth is now restored if the Mac reports waking twice while it is still turning Bluetooth back on.
- If turning Bluetooth off at sleep doesn't work the first time, Tannlaus now retries before the Mac sleeps instead of leaving Bluetooth on.
- The menu bar icon no longer stops responding for several seconds after wake while Bluetooth is turned back on.

## [0.2.0] - 2026-11-07

### Changed

- New app icon and menu bar icon: a tooth with the Bluetooth mark. Without Bluetooth access, the menu bar icon shows a warning sign instead of the Bluetooth mark.

## [0.1.0] - 2026-11-05

### Added

- Menu bar app that turns Bluetooth off when your Mac sleeps and restores it on wake.
- Menu with the current status, Launch at login, Hide icon and Quit.
- Clear "Bluetooth access denied" status with a shortcut to Privacy Settings when Bluetooth permission is missing.
