# The M3 pass: the JavaScript helper by hand

This page covers what M3 needs from a person. The tests do not cover it.

The helper's isolation and lifecycle are tested in-process (`PappuJSHostTests`), and the client's crash handling is tested against a helper that can be made to crash (`PappuRuntimeTests`). `PappuClip --check-js-host` runs the same things against the real, sandboxed `PappuClipJSHost.xpc`. What is left here is the sandbox as the system enforces it, and the Debug Console as a person reads it.

**Status: weeks 1 to 5; not yet run.** Build with `Scripts/build.sh PappuClip`. Record a run by filling in the Result column, dating it, and naming the macOS build.

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
- **W**: a JavaScript snippet, `#popclip` / `name: Hog` / `javascript: const a=[]; while(true) a.push(new Array(1e6).fill(1))`.
- **D**: a module snippet, `// #popclip` / `// name: Dynamo` / `// entitlements: [dynamic]` / `defineExtension({ actions: (input) => input.text.length < 20 ? [{ title: 'Echo ' + input.text, code: (i) => popclip.showText(i.text) }] : [] })`.
- **D2**: D with `actions: () => { setTimeout(() => {}, 1); return []; }`.
- **D3**: D with `actions: () => { while (true) {} }`.

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
| 10 | Repeat row 6 twice more within ten minutes | A "Crashed too often…" line; Spin leaves the bar until it is resumed in Extension Info (row 36) | |
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

## The watchdog (SEC-2, SEC-1d)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 34 | Press Spin (L) and leave it for 30 s | After about 30 s it fails with the X; the Debug Console has "Stopped by the watchdog" saying it kept a processor busy for 30 s, then the crash line | |
| 35 | Install W, press Hog and watch `PappuClipJSHost` in Activity Monitor | It is stopped as its memory passes 1.5 GB; the Debug Console has "Stopped by the watchdog" with the MB it used and the limit | |
| 36 | Press Hog twice more (after launchd's 10 s each time) | A "Crashed too often…" line; Hog leaves the bar; Extension Info shows it as "Stopped" with the sentence saying why and a Resume button. Press Resume: Hog is back on the bar and runs (and is stopped) again | |
| 37 | Let an extension be suspended as in row 36, then quit PappuClip and start it again | It is still "Stopped" in Extension Info and is not on the bar | |
| 38 | Install N, press Fetch and while it waits leave it for a minute with a slow or offline network | Not stopped by the watchdog; it ends only when the request does | |

## Sign-in (§8.10, SEC-8a)

Fixture **G**: a module snippet, `// #popclip` / `// name: Sign` / `// after: show-result` followed by `exports.auth = async (info, flow) => (await flow('https://example.com/', { redirect_uri: info.redirect }, ['code'])).code; exports.action = (input, options) => options.authsecret;`.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| G1 | Install and approve G, open its Extension Info | An Account section with "Not signed in to Sign." and Sign In… | |
| G2 | Press Sign In… | example.com opens in the browser with `redirect_uri=http://127.0.0.1:<port>/callback`; Info shows "Finish signing in in your browser." and Cancel Sign-In | |
| G3 | Visit `http://127.0.0.1:<port>/callback?code=abc` | The tab says it can be closed; Info shows "Signed in to Sign." and Sign Out; Keychain Access has an `app.pappuclip.extension-secret` item whose account ends `/#authsecret` | |
| G4 | Select a word and press Sign | `abc`; the Debug Console does not show `abc` for the sign-in | |
| G5 | Visit the same callback address again | The browser cannot connect: the listener took one callback | |
| G6 | Sign Out, then press Sign | The Debug Console has "Not signed in" | |
| G7 | Press Sign In…, then Cancel Sign-In | Info goes back to Sign In…; `lsof -iTCP -sTCP:LISTEN -a -c PappuClip` shows no listener left | |
| G8 | Install G again as a separate extension (change its identifier), sign the first in and press the second's action | "Not signed in": the second cannot read the first's secret | |

## Dynamic population and the warm helper (JS-13, JS-16, JS-19)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 39 | Quit PappuClip, install D, approve it, quit again, then launch and within a second check Activity Monitor | `PappuClipJSHost` is running before any selection is made | |
| 40 | Select `hello` in TextEdit | The bar has "Echo hello" after the static actions, on the first selection after launch; pressing it shows `hello` | |
| 41 | Select a sentence longer than 20 characters | No "Echo" item | |
| 42 | `kill -9` the `PappuClipJSHost` process, then press the mouse once in TextEdit without selecting | A new `PappuClipJSHost` process is running within a second; the next selection has "Echo …" again, or at worst the one straight after | |
| 43 | Install D2, approve it and select a word | No item from D2; the Debug Console has "A timer is not available in a population function." | |
| 44 | Install D3, approve it and select a word | The bar appears as fast as without D3, with no item from D3 (a population that never returns is ended only by the watchdog, §10.7) | |


## Import from PopClip and coexistence (EXM-11, EXM-15, ONB-6)

Week 6. The fixtures are in `~/Library/Application Support/PopClip/Extensions`. Make the folder if PopClip is not installed. **PS** is a `Search.popclipext` folder with a URL action. **PX** is a `Shout.popclipext` folder whose `Config.json` has `"shellScript": "echo hi"`. Keep a copy of `~/Library/Preferences/com.pilotmoon.popclip.plist` if there is one. Compare it afterwards to confirm that nothing in PopClip changed.

**The exclusion list's format is unverified.** PappuClip reads `BlockedApps` (an array of bundle IDs) from `com.pilotmoon.popclip.plist`. Row P1 checks that against a real PopClip.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| P1 | With a real PopClip, exclude Terminal in PopClip's settings, then run `defaults read com.pilotmoon.popclip BlockedApps` | Terminal's bundle ID in an array. If the key or the shape differs, note it here: `PopClipExclusions` is the one place to change | |
| P2 | Put PS and PX in the folder, finish onboarding, relaunch PappuClip | "Import from PopClip?" with the extension and excluded-app counts; Not Now closes it, and it is not offered at the next launch | |
| P3 | Open the menu bar item's menu | "Import from PopClip…" above Quit. Rename the Extensions folder, reopen the menu: it is gone | |
| P4 | Choose Import from PopClip…, then Review and Import… | One "Review Extensions" window: the unsigned-files sentence; Search under "Approved together…"; Shout under "These ask for more…" with a switch that is off and the script sentence | |
| P5 | With VoiceOver on, move to Shout's switch | It is read as "Approve “Shout”", then the script sentence | |
| P6 | Press Install with Shout's switch off | The closing alert says Search is on and Shout is waiting; Settings › Extensions shows Shout as "Waiting for approval"; Shout is not on the bar; Terminal is under Settings › Apps as "Don't appear automatically" | |
| P7 | Approve Shout in Extension Info | Shout is on the bar and runs | |
| P8 | Uninstall both, import again, turn Shout's switch on and press Install | Both are on; Shout is approved for scripts | |
| P9 | Import again and close the review window | Nothing is installed and no app rule is added; no closing alert | |
| P10 | Compare PopClip's folder and preferences with the copy | Unchanged | |
| P11 | With PappuClip running and "Appear automatically" on, start PopClip | "PopClip Is Running", which explains the two bars, with Keep Both, Turn Off PappuClip's Automatic Bar, How to Turn Off PopClip's, and "Don't show this again" | |
| P12 | Choose How to Turn Off PopClip's | The steps. Check that they match PopClip's current menu; PopClip keeps running and its settings are unchanged | |
| P13 | Quit and restart PopClip, then choose Turn Off PappuClip's Automatic Bar | The menu's "Appear Automatically" is unticked; the shortcut still brings the bar | |
| P14 | Turn "Appear automatically" back on, tick "Don't show this again", restart PopClip twice | The notice appears once, then not again | |
| P15 | With PopClip running, select text in an app with no Accessibility text (e.g. a canvas app with a copyable selection) | The automatic bar does not copy (the pasteboard's change count is unchanged); the shortcut still reads the selection | |
| P16 | Launch PappuClip with PopClip already running | The notice appears at launch, unless it was suppressed | |

## File types and development folders (EXM-4, DEV-1)

Fixture **V**: a folder `Dev.popclipext` holding `Config.json` with `{"name": "Dev", "identifier": "com.example.dev", "actions": [{"title": "Search", "url": "https://example.com/?q=***"}]}`. For V2, add a second action `{"title": "Hi", "javascript": "popclip.showText('hi')"}`; for V3, add `{"title": "Shout", "shellScript": "echo hi"}`.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| FT1 | `plutil -p` the built app's `Contents/Info.plist` | `CFBundleDocumentTypes` names the three `com.pilotmoon.popclip.extension*` types with `LSHandlerRank` `Alternate`; they are under `UTImportedTypeDeclarations` and not under `UTExportedTypeDeclarations`; no type has rank `Default` | |
| FT2 | With PopClip installed, Get Info on a `.popclipextz` in Finder | "Open with" still shows PopClip as the default; PappuClip is in the Open With list | |
| FT3 | Open With → PappuClip on a `.popclipextz`, and again on a `.popcliptxt` | The install review appears for each; Cancel installs nothing | |
| DV1 | Settings → Developer on a fresh install | No development-mode banner; "No development folders."; both switches off | |
| DV2 | Add Folder… and choose V | The install review says "Development folder…" (unsigned, unreviewed); Install adds the row; the banner "Development mode is on" appears; the menu bar menu starts with "Development Mode On" | |
| DV3 | Press Reload without changing V | "No changes to load." | |
| DV4 | Change V's Search title and press Reload | "Reloaded." with no review; the bar shows the new title | |
| DV5 | Make V into V3 and press Reload | The review appears again with the script switch off and Update / Cancel only; Cancel says "Not reloaded…" and the bar still has the old version | |
| DV6 | Turn on "Allow Safari Web Inspector" with V2 approved, select text and open Safari → Develop → this Mac | The PappuClipJSHost context for Dev is listed; a JavaScript extension installed normally is not. Turn the switch off: it is gone after the next selection | |
| DV7 | Turn on "Verbose extension logging" and press Hi | The Debug Console has `[development]` lines for the load, the run and the host call, with no selected text in them; other extensions write no such lines | |
| DV8 | Press Remove on V's row | The row, banner and menu status line go; V's folder on disk is untouched | |

## The rich result panel and the text prompt (JS-17, JS-18, RUN-2e, BAR-17)

Fixtures:
- **RR**: a JavaScript snippet, `#popclip` / `name: Rich Result` / `pappuAfter: rich-result` / `javascript: return popclip.input.text.toUpperCase() + '\n\nsecond line'`.
- **MD**: a JavaScript snippet, `#popclip` / `name: Show MD` / `javascript: popclip.showResult('**bold** _it_ [link](https://example.com) <b>raw</b>', { format: 'markdown' })`.
- **Q**: a JavaScript snippet, `#popclip` / `name: Ask` / `after: paste-result` / `javascript: return 'Hello, ' + await pappuclip.promptText({ label: 'Your name', placeholder: 'name', defaultValue: 'World' })`.

The panels are the functional M3 ones; their look is M4's (DIF-1a, DIF-3). Replace Selection and Insert re-check the destination when clicked. A click on a PappuClip panel counts as input to apps that are checked only by quiescence (the unverifiable and quiescence tiers of §9.2), so there Replace and Insert are expected to be refused with an explanation, and Copy still works. That is the known M3 limitation, not a failure.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 45 | Install and approve RR, select `hello` in TextEdit and press Rich Result | A panel near the selection shows `HELLO` and `second line` on two lines; TextEdit keeps focus (its caret still blinks); the clipboard is unchanged (`pbpaste`) | |
| 46 | Press Copy | "Copied" in the panel; `pbpaste` gives the whole result; the panel stays open | |
| 47 | Run RR again and press Replace Selection | `hello` is replaced with the result and the panel closes; the clipboard is what it was before | |
| 48 | Run RR again and press Insert | `hello` stays, followed by the result; the panel closes | |
| 49 | Run RR again, click elsewhere in the TextEdit document, then look at the panel and press Replace Selection | Replace Selection and Insert are disabled with "The selection has changed since the action ran" (or "Focus has moved…") under them and in their tooltips; nothing is written; Copy still works | |
| 50 | Run RR again, switch to another app, then press Replace Selection | Refused with "The app the text came from is no longer in front"; Copy still works | |
| 51 | Run RR in Safari's address bar or another quiescence-tier app and press Replace Selection | Either written, or refused with the typing-or-clicking explanation; never written somewhere else | |
| 52 | Run RR and press Escape, then again and press Close, then again and click the window's close button | The panel goes each time; the Debug Console shows each invocation completed; nothing written | |
| 53 | Run RR, then pause PappuClip from the menu bar while the panel is open | The panel closes at once | |
| 54 | Install and approve MD and press Show MD | `bold` in bold, `it` in italics, `link` as plain text that opens nothing when clicked, and `<b>raw</b>` shown as written | |
| 55 | With VoiceOver on, run RR and move through the panel | VoiceOver reads the result text, then Copy, Replace Selection, Insert and Close by name; a disabled Replace says why; pressing Copy announces "Copied" | |
| 56 | Install and approve Q, select a word and press Ask | A prompt titled PappuClip shows "Your name", a field holding `World` with focus in it, "Asked by Ask" under it, and Submit and Cancel | |
| 57 | Type `Ann` and press Return | The selection is replaced with `Hello, Ann` | |
| 58 | Run Q, clear the field and press Submit | `Hello, ` is pasted: an empty answer is an answer | |
| 59 | Run Q and press Escape; again and press Cancel; again and close the window | Nothing is pasted each time; the Debug Console shows the invocation cancelled | |
| 60 | Run Q and, with the prompt up, pause PappuClip from the menu bar | The prompt closes; nothing is pasted | |
| 61 | With VoiceOver on, run Q | VoiceOver announces the field as "Your name, edit text, World"; Tab reaches Cancel and Submit; Return submits and Escape cancels without the mouse | |
| 62 | Install a dynamic extension whose population calls `pappuclip.promptText({ label: 'x' })`, approve it and select a word | No prompt appears; the Debug Console has "promptText is not available in a population function." | |


## Week 7: `pappuclip run`, the corpus pass and the built-ins (DEV-2)

Build the CLI with `swift build --product pappuclip` in `Packages/PappuKit`; it is at `.build/debug/pappuclip`. The fixtures are the conformance suites under `Tests/conformance`, and a scratch package **R**: a folder `R.popclipext` holding `Config.js` with `exports.test = (input) => { print('ran'); return input.text.toUpperCase(); }; exports.broken = () => { throw new Error('nope'); }; exports.keys = () => popclip.pressKey('cmd b');`.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| CL1 | `pappuclip run Tests/conformance/environment/suite.js; echo $?` | Two `require(...) found nothing` lines, then `ok`, `passed` and `0` | |
| CL2 | `pappuclip run Tests/conformance/api/suite.js; echo $?` | `host:` lines for each call, four of them `refused:` (pressKeys, performService, runShellScript, httpRequest); then `ok`, `passed`, `0`. No browser opens, nothing is pasted, and `pbpaste` is unchanged | |
| CL3 | `pappuclip run R.popclipext/Config.js --text abc; echo $?` | `ran`, `ABC`, `passed`, `0` | |
| CL4 | `pappuclip run R.popclipext/Config.js broken; echo $?` | `failed: Error: nope` and `1` | |
| CL5 | `pappuclip run R.popclipext/Config.js missing; echo $?` | `error: The module exports no function missing.` and `1` | |
| CL6 | `pappuclip run R.popclipext/Config.js keys`, then again with `--allow synthetic-input` | First: refused with "pressKeys needs the synthetic-input permission…" and exit 1. Second: `host: pressKeys … -> done`, exit 0, and no key reaches the frontmost app | |
| CL7 | `pappuclip run --help` | Lists `--text`, `--option`, `--allow`, `--clipboard`, `--timeout`, `--script` and `--quiet` | |
| CF1 | In `Packages/PappuKit`, `swift run pappu-dev corpus functional --dry-run --verbose` (the `Tests/corpus` submodule checked out) | One line per package that did not pass, each with its verdict (`blocked`, `load-only`, `untested`, `failed`) and why, then `N/381 functional (…%): …`. No browser opens, nothing is pasted, no key is pressed, no Service or Shortcut runs, and `pbpaste` is unchanged | |
| CF2 | The same without `--dry-run` | Also `wrote …/Tests/results/corpus-functional/<timestamp>-macOS<version>-<arch>.json`; `pappu-dev results summarize` on it shows `functional-rate` and the counts; the file has no host name, user name or home path | |
| CF3 | Install the corpus's `source/Email.popclipext`, approve it, turn on both of its actions in its settings and select `someone@example.com` in TextEdit | "New email to someone@example.com" (@ icon) and "New email with text" (envelope icon) are on the bar. Before this week both were left out, because their icons are package files | |
