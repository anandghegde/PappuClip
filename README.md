# PappuClip

A free, open-source selection bar for macOS: select text, and a small bar of actions appears next to it. It aims to
run existing PopClip extensions unchanged.

**Status: pre-alpha, milestone M2 (running PopClip extensions) in progress.** There is an app that builds and
nothing anyone should rely on:
- M1 assembled the bar, the five built-in actions, the menu bar item, Settings and the onboarding flow. Nobody has run it
  for long enough to call it working.
- M2 has begun with the extension parser, the extension store and the first executors. The parser loads 368 of the
  381 extensions in PopClip's public repository (`swift run pappu-dev corpus load`), and every one that loads also
  installs into the store. URL, Key Press and Shortcut actions can run, together with every `before` and `after`
  step, and a result can be shown in the bar. Scripts and JavaScript cannot run yet, and the app does not show
  installed extensions yet.

The M0 spikes still need a Mac with a person at it ([what is left](docs/spikes/RUNBOOK.md)), and `SpikeLab` is the
throwaway app that runs them.

PappuClip is an independent project. It is not affiliated with, endorsed by, or derived from the code of PopClip or
Pilotmoon Software. "PopClip" is their trademark and is used here only to describe compatibility.

## Documents

| | |
|---|---|
| [Product requirements](docs/PRD.md) | What it does, for whom, and the requirement IDs everything else refers to |
| [Safety specification](docs/spec/safety.md) | Clipboard transactions, invocation safety, consent |
| [Extension platform](docs/spec/extension-platform.md) | Package format and the JavaScript runtime |
| [Architecture](docs/architecture.md) | Processes, modules, and the mechanisms that enforce the safety rules |
| [Implementation plan](docs/implementation-plan.md) | Milestones M0 to M6 |
| [Spike reports](docs/spikes/) | What M0 found, and [what is left to run](docs/spikes/RUNBOOK.md) |

## Building

Requires macOS 15 or later, Xcode 26 (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
# The package: every module, the unit tests, the repository checks
cd Packages/PappuKit
swift build
swift test
swift run pappu-dev trace check      # Tests/traceability.yaml against the design documents and the tests

# The app targets: `Scripts/build.sh [scheme] [configuration]`, default SpikeLab Debug
Scripts/setup-dev-signing.sh         # once per Mac; see below
Scripts/build.sh PappuClip           # generates App/PappuClip.xcodeproj and builds the app into build/
open build/DerivedData/Build/Products/Debug/PappuClip.app

Scripts/build.sh                     # SpikeLab, for the M0 spikes
open build/DerivedData/Build/Products/Debug/SpikeLab.app
```

PappuClip is a menu-bar agent: there is no Dock icon and no window at launch, only a paperclip in the menu bar and,
the first time, a window explaining why it wants the Accessibility permission. Without that permission no bar appears
on a selection, and the first item in the menu says so. `tccutil reset Accessibility app.pappuclip.PappuClip` puts a
Mac back to never having been asked.

### Why a signing certificate

macOS ties the Accessibility permission to an app's code signature. An unsigned or ad-hoc-signed build gets a new
signature every time it is compiled, so macOS forgets the permission on every rebuild.
`Scripts/setup-dev-signing.sh` creates a self-signed certificate in your login keychain that stays the same between
builds. It is trusted by nobody and cannot be used to distribute anything. To use a certificate you already have:

```sh
PAPPU_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/build.sh
```

Without either, the build falls back to ad-hoc signing and warns.

### Running a spike

Use the SpikeLab window, or:

```sh
Scripts/run-spike.sh --list
Scripts/run-spike.sh spike-2-taps --state "Accessibility only"
```

Results are written to `Tests/results/` ([format](Tests/results/README.md)). Do not run the SpikeLab binary
straight from a shell for anything you intend to keep: macOS then treats your terminal as the responsible process,
and every permission result describes the terminal.

## Repository layout

`Packages/PappuKit` holds all the code as one SwiftPM package with a target per module; `App/` holds the thin Xcode
targets that host it. [Architecture §15](docs/architecture.md#15-repository-layout) has the full map.

## Licence

[MIT](LICENSE). The app reuses no code from the GPL-3.0 selection-detection projects, so the permissive option in
[PRD §13](docs/PRD.md) applies. Extensions are separate works and may use any licence.
