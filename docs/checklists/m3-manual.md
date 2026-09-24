# The M3 pass: the JavaScript helper by hand

This page covers what M3 needs from a person. The tests do not cover it.

The helper's isolation and lifecycle are tested in-process (`PappuJSHostTests`), and the client's crash handling is tested against a helper that can be made to crash (`PappuRuntimeTests`). `PappuClip --check-js-host` runs the same things against the real, sandboxed `PappuClipJSHost.xpc`. What is left here is the sandbox as the system enforces it, and the Debug Console as a person reads it.

**Status: weeks 1 and 2; not yet run.** Build with `Scripts/build.sh PappuClip`. Record a run by filling in the Result column, dating it, and naming the macOS build.

Fixtures:
- **J**: a JavaScript snippet, `#popclip` / `name: Shout JS` / `javascript: print(popclip.input.text); return popclip.input.text.toUpperCase()`, with `after: paste-result`.
- **L**: a JavaScript snippet, `#popclip` / `name: Spin` / `javascript: while (true) {}`.
- **T**: a TypeScript code snippet, `// #popclip` / `// name: Title TS` / `// after: paste-result` followed by `import { titleCase } from 'case-anything'` and `return titleCase(popclip.input.text) as string`.

## The helper (SEC-1a, SEC-1b, SEC-1d)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 1 | `build/DerivedData/Build/Products/Debug/PappuClip.app/Contents/MacOS/PappuClip --check-js-host` | Every line PASS; exit 0 | |
| 2 | `codesign -d --entitlements - …/PappuClip.app/Contents/XPCServices/PappuClipJSHost.xpc` | `com.apple.security.app-sandbox` and nothing else but `get-task-allow` in a debug build | |
| 3 | Install J, select a word in TextEdit and press Shout JS | The word is replaced in capitals | |
| 4 | In Activity Monitor, find `PappuClipJSHost` and check its Sandbox column | Yes | |
| 5 | Install L, press Spin, then press Escape | The bar's spinner stops within a second; the next Shout JS still works (after up to 10 s) | |
| 6 | Press Spin and force-quit `PappuClipJSHost` in Activity Monitor instead | Spin fails with the X; the bar and the app stay up | |

## The Debug Console (DIA-1)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 7 | Menu bar → Debug Console after row 3 | "Shout JS", the printed word, then "Returned:" with the capitals | |
| 8 | After row 5 | "Spin", "Did not stop when asked; the JavaScript helper was restarted", then "Stopped" | |
| 9 | After row 6 | "Spin", "The JavaScript helper stopped while this was running" | |
| 10 | Repeat row 6 twice more within ten minutes | A "Crashed too often…" line; Spin does nothing until PappuClip is restarted | |
| 11 | Copy All, then Clear | The lines are on the clipboard; the window says there is nothing yet | |

## The language environment (JS-2, JS-9, JS-14)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 12 | Row 1's `--check-js-host` | Its lines include "the environment and a bundled library load in the helper" and "TypeScript is transpiled in the helper", both PASS | |
| 13 | `ls …/PappuClip.app/Contents/XPCServices/PappuClipJSHost.xpc/Contents/Resources/` | A `PappuKit_PappuJSHost.bundle` holding `JavaScript/environment.js`, `JavaScript/libraries/` and `JavaScript/THIRD-PARTY-NOTICES.txt` | |
| 14 | Install T, select `hello big world` in TextEdit and press Title TS | The words are replaced by `Hello Big World` | |
| 15 | Press Title TS a second time, then open the Debug Console | It worked again, and the console shows no error from loading `case-anything` | |
