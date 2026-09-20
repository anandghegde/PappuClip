# PappuClip

A free, open-source selection bar for macOS: select text, and a small bar of actions appears next to it. It aims to
run existing PopClip extensions unchanged.

**Status: pre-alpha, milestone M0 (technical spikes).** There is no app to use yet. What exists is the design, the
package skeleton, and `SpikeLab`, a throwaway app that runs the experiments the design depends on.

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

# The app targets
Scripts/setup-dev-signing.sh         # once per Mac; see below
Scripts/build.sh                     # generates App/PappuClip.xcodeproj and builds SpikeLab into build/
open build/DerivedData/Build/Products/Debug/SpikeLab.app
```

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

Not chosen yet. The choice between GPL-3.0 and MIT depends on what the M0 spikes show about code reuse and is made
at M0 exit, before the project accepts outside contributions ([PRD §13](docs/PRD.md)). Until a `LICENSE` file
appears, no licence is granted.
