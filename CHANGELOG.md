# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Bluetooth stays on while your Mac laptop sleeps docked to an external display, lid open or closed, so a Bluetooth keyboard can wake it. Unplugging the display while the Mac sleeps turns Bluetooth off.
- "Keep Bluetooth on when docked" menu setting on laptops, on by default; turn it off to have Bluetooth off at every sleep as before.

## [1.0.0] - 2026-11-09

First public release.

### Added

- Menu bar app that turns Bluetooth off when your Mac sleeps and restores it on wake.
- Menu with the current status, Launch at login, Hide icon and Quit.
- Clear "Bluetooth access denied" status with a shortcut to Privacy Settings when Bluetooth permission is missing; the menu bar icon then shows a warning sign.
- The menu shows "Not working: unsupported macOS version", and the icon stays visible, if a macOS update stops Tannlaus from switching Bluetooth.
