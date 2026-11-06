# Changelog

What changed in each version of DeskBar. Downloads are on the
[releases page](https://github.com/Osman246/DeskBar/releases).

## Unreleased

### Project
- Every push and pull request is built and tested by GitHub Actions, and releases are built there
  from the tagged commit, with a SHA-256 and a build attestation.
- Tests for the verdict: when each problem appears, what it says, and which one wins the headline.
- The demo film's code lives in its own folder, `Sources/DeskBar/DemoFilm`.

## [1.1.2] – 2026-11-05

### New
- An app icon: a MacBook whose screen shows a green check.
- DeskBar's own row in the CPU, memory and battery lists says "This app" instead of offering Quit.

## [1.1.1] – 2026-11-05

### Fixed
- "No internet" when you're online. The check pinged 1.1.1.1, and some networks drop pings while
  everything else works. It now times a normal connection to 1.1.1.1 on port 443, falling back to
  1.0.0.1.

## [1.1] – 2026-11-05

The redesign after launch feedback: the answer first, everything else when you ask.

### New
- The top card says *All good*, or names the one thing that isn't, with the fix next to it.
- A quiet menu bar: a small MacBook when all's clear, and a warning only when something needs you.
- Today: a short daily report on the busiest and hottest apps, data downloaded, and how today
  compares with your usual day.

### Changed
- The panel is 35% shorter. The 3D Mac is a thumbnail beside the verdict; click it for the full view.
- The panel is DeskBar's own, on the standard frosted popover material.
- Faster launch: the first frame draws in about 30 ms, and a 0.9 s pause after launch is gone.

## [1.0] – 2026-10-29

First release.

- One health verdict, with detail one click away: CPU, heat and fans, memory, disk, battery, Wi-Fi
  and network.
- A living 3D MacBook that mirrors your real one: lid angle, MagSafe and charging, monitors and
  labelled ports.
- Smart alerts in plain English, quick actions, and a full window with history charts.
- No account and no analytics. Every network call is listed in the README.

[1.1.2]: https://github.com/Osman246/DeskBar/releases/tag/v1.1.2
[1.1.1]: https://github.com/Osman246/DeskBar/releases/tag/v1.1.1
[1.1]: https://github.com/Osman246/DeskBar/releases/tag/v1.1
[1.0]: https://github.com/Osman246/DeskBar/releases/tag/v1.0
