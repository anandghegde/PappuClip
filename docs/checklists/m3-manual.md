# The M3 pass: the JavaScript helper by hand

This page covers what M3 needs from a person. The tests do not cover it.

The helper's isolation and lifecycle are tested in-process (`PappuJSHostTests`), and the client's crash handling is tested against a helper that can be made to crash (`PappuRuntimeTests`). `PappuClip --check-js-host` runs the same things against the real, sandboxed `PappuClipJSHost.xpc`. What is left here is the sandbox as the system enforces it, and the Debug Console as a person reads it.

**Status: weeks 1 to 4; not yet run.** Build with `Scripts/build.sh PappuClip`. Record a run by filling in the Result column, dating it, and naming the macOS build.

Fixtures:
- **J**: a JavaScript snippet, `#popclip` / `name: Shout JS` / `javascript: print(popclip.input.text); return popclip.input.text.toUpperCase()`, with `after: paste-result`.
- **L**: a JavaScript snippet, `#popclip` / `name: Spin` / `javascript: while (true) {}`.
- **M**: a module snippet, `// #popclip` / `// name: Mod` / `// after: paste-result` followed by `export default { actions: [{ title: 'Reverse', code: (input) => [...input.text].reverse().join('') }] }`.
- **T**: a TypeScript code snippet, `// #popclip` / `// name: Title TS` / `// after: paste-result` followed by `import { titleCase } from 'case-anything'` and `return titleCase(popclip.input.text) as string`.
- **H**: a JavaScript snippet, `#popclip` / `name: Host` / `javascript: await popclip.pasteText(util.base64Encode(popclip.input.text)); popclip.showSuccess()`.
- **K**: a JavaScript snippet, `#popclip` / `name: Bold Key` / `javascript: await popclip.pressKey('command b')`.
- **R**: a JavaScript snippet, `#popclip` / `name: Rich` / `javascript: popclip.copyContent({ 'public.rtf':new RichString('# Big\n\n**bold** and [a link](https://example.com)', { format:'markdown' }).rtf })` (no space after either colon, so the line stays one YAML value).
- **S**: a JavaScript snippet, `#popclip` / `name: Styled` / `capture html: true` / `javascript: popclip.showText(popclip.input.markdown)`.
- **A**: a snippet, `#popclip` / `name: Needs App` / `app: {name: Nowhere, link: "https://example.com/", checkInstalled: true, bundleIdentifiers: [com.example.nowhere]}` / `url: https://example.com/?q=***`.
- **B**: a snippet, `#popclip` / `name: Broken` / `interpreter: nosuchshell` / `shell script: echo hi`.
- **N**: a JavaScript snippet, `#popclip` / `name: Fetch` / `entitlements: [network]` / `network hosts: [api.github.com]` / `javascript: const r = await axios.get('https://api.github.com/zen'); return r.data`, with `after: show-result`.
- **N2**: N with its URL changed to `https://example.com/`.
- **X**: a JavaScript snippet, `#popclip` / `name: Scripts` / `entitlements: [script]` / `after: show-result` / `javascript: return (await $`sw_vers -productVersion`) + ' ' + (await popclip.runAppleScript('return name of application "Finder"'))`.
- **Y**: a JavaScript snippet, `#popclip` / `name: Alias` / `entitlements: [script]` / `javascript: const p = globalThis['pop' + 'clip']; p.runShellScript('echo hi')`.

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
| 15a | Save T as `Title.ts` in the Finder, then Control-click it → Open With (EXM-3) | PappuClip is listed but is not the default; choosing it shows the install review for "Title TS" | |
| 15b | Drag `Title.ts`, then a `.txt` file, onto the menu bar icon | The first is taken and shows the same review; the icon does not take the second | |

## Module extensions (JS-12)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 16 | Install M and approve it, then select `hello` in TextEdit | Within a second or so of approving, a Reverse button; pressing it replaces the word with `olleh` | |
| 17 | Quit PappuClip, start it again, select `hello` | Reverse is there again once the helper has described the module (it starts at launch for this) | |
| 18 | Install M again with `code:` taken out of its action | No Reverse button; the Debug Console has nothing about it, and Extension Info still lists the extension | |

## The host API (JS-3, JS-4, JS-6, JS-7, SEC-7b)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 19 | Install H, select `hello` in TextEdit and press Host | The word becomes `aGVsbG8=`, the bar shows a tick, and ⌘Z puts `hello` back in one step | |
| 20 | Install K, approving it without "Can type and press keys", select a word in TextEdit and press Bold Key | The X; the word is not bold; the Debug Console has "Not allowed" with `pressKeys:` and the reason, and not the word | |
| 21 | In Extension Info, turn "Can type and press keys" on for K and press Bold Key again | The word becomes bold | |
| 22 | Install R, press Rich on any selection, and paste into a new TextEdit document | A large heading "Big", then **bold** and a link; Little Snitch or `nettop` shows no connection from PappuClip | |
| 23 | Install L again, press Spin and then Escape; within a second press Host on a new selection | Host works on its own selection; nothing from Spin's run is pasted or copied later | |

## Capture, messages and missing apps (FLT-4, BAR-13, EXM-10)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 24 | Install S. In TextEdit, type `one two three`, make `two` bold with ⌘B, select the line and press Styled | The bar shows `one **two** three` | |
| 25 | Select the same words in Safari's address field and press Styled | The bar shows `one two three`, with no `**` | |
| 26 | Install A, select any word and press Needs App | An alert, "“Nowhere” is not installed", with Open Website and OK; no search page opens. Open Website opens `https://example.com/` | |
| 27 | Install B, approving it, select any word and press Broken | Grey text in the bar, "“Broken” could not start. The Debug Console says why.", which stays until you click elsewhere; the Debug Console has a line saying why | |

## Network, scripts and the scan (JS-5, JS-8, SEC-1c, SEC-6, EXM-5f)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 28 | Install N | The consent sheet lists "Can send data to api.github.com." and has no network switch and no "Runs code whose reach…" switch | |
| 29 | Approve N, select any word and press Fetch | The bar shows a short GitHub saying; `nettop` shows the connection from PappuClip, not from `PappuClipJSHost` | |
| 30 | Install N2, approve it and press Fetch | The X; the Debug Console has "Not allowed" with `httpRequest may only reach the hosts the extension declares`; `nettop` shows no connection to `example.com` | |
| 31 | Install X, approving it with "Can run scripts", and press Scripts | The macOS version and `Finder`; the first AppleScript may ask to control Finder, and the Debug Console names what failed if it is refused | |
| 32 | Make a Shortcut named `Echo` that returns its input, then in X call `popclip.runShortcut('Echo', 'hi')` and press Scripts | `hi` | |
| 33 | Install Y | Switches for scripts and for typing keys, and one "Runs code whose reach this version of PappuClip cannot check, and which can call…" switch whose sentence lists the methods, `runShellScript` and `pressKey` among them; no switch per method | |
