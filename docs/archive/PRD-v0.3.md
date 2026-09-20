# PappuClip — Product Requirements Document

| | |
|---|---|
| **Status** | Draft v0.3 |
| **Date** | 2026-09-20 |
| **Name** | PappuClip (decided; see the trademark note in §14) |
| **Model** | Fully open source and free. No paid tiers, trials or licence keys |
| **Platform** | macOS 14+ (Apple Silicon and Intel) |
| **Reference baseline** | PopClip 2026.8.1 (build 6221, released 2026-09-07), as documented on popclip.app on 2026-09-20 |

**How to read this document.** Every requirement has an ID and a priority:

- **P0** — needed for the first usable build (the core bar and the basic extension runtime).
- **P1** — needed for 1.0: reference-baseline parity with explicit safety exceptions, a verified extension ecosystem, and the selection-first improvements in §10.
- **P2** — after 1.0. These are mostly differentiators that PopClip does not have.

Facts about PopClip come from its public website, developer docs, type definitions, localization strings, GitHub repos and forum. Anything the research could not confirm is marked *(unverified)* and collected in §17.

---

## 1. Summary

PappuClip is a free, fully open-source macOS utility that shows a small floating bar when you select text, or a searchable action palette when you press a shortcut. It combines PopClip extension compatibility with less intrusive interaction and safer text handling. It has three pillars:

1. **The app.** End-user parity with PopClip 2026.8.1, subject to documented safety exceptions: automatic appearance on selection, eight built-in actions, content-aware filtering, an organisable action list, app and website rules, keyboard control, iCloud sync and an AppleScript interface. Version 1.0 adds a searchable palette, rich results, per-app action sets and simple extension input prompts.
2. **The extension platform.** A runtime that loads PopClip's extension format unmodified: `#popclip` snippets, `.popclipext` packages, all seven action types, the JavaScript/TypeScript API, options, authentication and icons. Native additions use separate keys or methods; consent, privacy and destination-safety checks apply to both formats.
3. **The ecosystem.** A PappuClip-run extension directory with a GitHub-based publishing pipeline, review, signing, automatic updates and one-click install, launched with a catalogue ported from PopClip's MIT-licensed extensions.

The compatibility promise is the core of the strategy. A user switching from PopClip keeps their extensions, and an extension author can publish to both ecosystems from one repo. Compatibility does not bypass capability approval, privacy blocks or safe text replacement.

---

## 2. Background

### 2.1 PopClip today

- A single developer (Nick Moore, Pilotmoon Software) has built it since 2011.
- It left the Mac App Store in March 2024 because the app cannot be sandboxed. It now sells as a standalone app (about $12 for a licence with two years of updates, about $32 lifetime — re-check before quoting, the buy page loads prices dynamically) and through Setapp. The trial allows 250 actions and then nags.
- Release 2026.7 (July 2026) was a major overhaul and the first paid update. It added iCloud sync, unlimited actions, folders, separators, page breaks, multiple instances of an extension, an icon picker, extension auto-update and richer option sheets.
- Since 2026.8 the eight built-in actions are themselves bundled extension snippets.
- The extension directory lists roughly 250–283 extensions depending on how they are counted. About 222 are by the developer. The first-party extensions repo is MIT-licensed.
- Since August 2026, authors publish from their own GitHub repo by pushing a git tag. Automated checks run, the developer reviews by hand, and the server signs the package.

### 2.2 Competitive landscape

| Product | Model | Relevance |
|---|---|---|
| PopClip | Popup bar on selection; 7 extension action types | The baseline |
| SnipDo (Windows) | Popup bar; `.pbar` extensions | Shows the concept travels across platforms |
| Alfred Universal Actions, LaunchBar Instant Send | Hotkey opens an action panel for the selection | Preferred by users who dislike an automatic popup |
| Raycast | Launcher with selection-aware commands and a very large extension store | Strongest ecosystem and AI offering; no popup on selection |
| Apple Writing Tools | System proofreading and rewriting | Free but not extensible, and missing in many web editors |
| Easydict, Bob, Pot | Selection translation | Translation only; several ship PopClip extensions |
| Open-source clones (openclip, SnapBar, Xpop, PopGuy, ClipBar) *(unverified beyond their READMEs)* | Various | Early stage. Which ones PappuClip can borrow code from depends on the licence it picks (§13) |

### 2.3 Gaps in PopClip that users raise

These come mostly from the PopClip forum and Mac Power Users. They inform the launch and post-launch differentiators in §10.

1. **Intrusiveness.** Some users abandon the automatic popup for hotkey-driven tools.
2. **Reliability in Electron and web apps.** A cursor-shape heuristic caused failures in Obsidian, Drafts and Ulysses. The "can't fix" list is long.
3. **Clipboard side effects.** The copy-simulation fallback registers as a clipboard change and disturbs clipboard managers and macros.
4. **Result display.** Results show as one truncated line, which is poor for AI and translation output.
5. **Extension experience.** There is no in-app store, no ratings or install counts, no way to edit an extension in place, and no way for an extension to prompt for input.
6. **Open requests.** Actions that vary by app, clipboard history, auto-copy, and a modifier key that requires or suppresses the bar.

---

## 3. Goals, non-goals and success metrics

### 3.1 Goals

| ID | Goal |
|---|---|
| G1 | End-user feature parity with PopClip 2026.8.1, except where documented safety requirements take precedence |
| G2 | Extension compatibility: publicly available PopClip extensions load and run unmodified, subject to capability approval and safety checks |
| G3 | A self-sustaining ecosystem: directory, publishing, review, signing, updates, discovery |
| G4 | Reliability at least equal to PopClip in the most-used Mac apps, and better in Chromium and Electron apps |
| G5 | A security model for third-party code that users can understand and trust |
| G6 | Everything is open source and free: the app, the extension SDK and types, the directory backend and the ported extensions |
| G7 | Less intrusive, selection-first interaction: searchable actions, usable multiline results and predictable per-app action sets |

### 3.2 Non-goals for 1.0

- Paid tiers, trials, licence keys or any feature gating.
- Windows, Linux or iOS versions.
- Mac App Store distribution (technically impossible for this class of app; see §13).
- Becoming a clipboard manager, a general-purpose launcher or a full workflow editor. The action palette operates on the current selection/context only.
- Operating an AI service. AI features use the user's own keys or local models.
- Verifying Pilotmoon's extension signatures. The format is undocumented, so PopClip-signed packages are treated as unsigned.
- Appearing automatically for keyboard-only selections. PopClip does not do this either; the keyboard shortcut covers it.

### 3.3 Success metrics

| Metric | Target for 1.0 |
|---|---|
| Time from mouse-up to bar visible (Accessibility path) | ≤ 150 ms at p95 |
| Time from mouse-up to bar visible (clipboard fallback path) | ≤ 350 ms at p95 |
| Frozen compatibility corpus that loads without error | ≥ 98%; denominator and exclusions below |
| Frozen compatibility corpus that passes a functional smoke test | ≥ 95%; blocked and untested cases are not passes |
| Tier A apps in the compatibility matrix (§11.5) with working auto-appear | 100% |
| Crash-free sessions | ≥ 99.8% |
| Idle CPU | < 0.5%, with no polling |
| Launch catalogue quality | Every required workflow in §9.5 covered; every launch package reviewed and functionally verified; 150 packages is a stretch target, not a release gate |
| Clipboard integrity | 0 lost newer clipboard writes; 0 temporary fallback contents left behind when restoration is safe, in the race/integrity suite |
| False-positive automatic appearances | ≤ 1% of labelled non-trigger interactions in the release gesture corpus; 0 secure-input or hard privacy-block violations |
| Wrong-destination insertion or post-cancellation insertion | 0 occurrences in the action-lifecycle suite (§7.14) |
| Extension recovery | Failed updates preserve the working version; rollback, revocation and safe-mode scenarios pass |

**Measurement definitions.** Freeze the upstream MIT-repository commit and enumerate all extension packages before beta. Publish a manifest with per-package licence eligibility, action types, dependencies and results. Exclude only packages without redistribution/test permission or for confirmed discontinued services, with reasons recorded before testing. The remaining packages are the common denominator for load and functional percentages; do not shrink it to the tested subset. A functional pass exercises the advertised action and observes its result, with supported app dependencies and dedicated test credentials where needed. Report load-only, dependency/credential-blocked, failed and untested cases separately; none counts as a functional pass. Native ported packages have their own launch-verification record and do not replace the unmodified compatibility corpus.

The gesture corpus records expected trigger/non-trigger outcomes, app and macOS version, strategy and latency. Non-trigger cases include ordinary clicks, drags of non-text content, scrolling, keyboard-only selection and suppression rules. False-positive rate is unexpected appearances divided by non-trigger interactions. Measure latency end-to-end, including content filtering and dynamic actions, on declared Apple Silicon and Intel reference machines with 50 installed extensions. Collect measurements in the test harness and opt-in beta diagnostics, not selection/app-usage analytics.

---

## 4. Users and use cases

| Persona | Needs |
|---|---|
| **Everyday user** (writer, student, researcher) | Copy and paste without keyboard shortcuts, look up and search selected words, fix spelling, open links in plain text |
| **Power user** | Send text to notes and task apps, run Shortcuts and scripts, organise dozens of actions, sync across Macs |
| **Developer** | Format JSON, convert case and encodings, run the selection in a terminal, look up docs |
| **Extension author** | A simple format, quick iteration, good docs and types, a painless publishing flow |
| **App vendor** | Ship an official extension for their app and get listed |
| **PopClip switcher** | Bring existing extensions and settings across with no rework |

Representative flows:

1. Select a word in Safari → the bar appears above it → click **Copy** → the bar shows "Copied" and disappears.
2. Click and hold in an empty text field for half a second → the bar appears with **Paste**.
3. Select `~/Documents/report.pdf` in a chat → the bar offers **Reveal in Finder**.
4. Select a snippet beginning `#popclip` on a forum → the bar offers **Install Extension "Name"**.
5. Press the global shortcut with text selected in a JetBrains IDE → type "format JSON" in the action palette → Return → inspect the multiline result → replace the verified original selection.
6. An author pushes tag `v1.2.0` to their GitHub repo → checks run → review → the signed package appears in the directory → installed copies update atomically, pausing for approval if capabilities increase.
7. Start a translation in Notes → switch to Terminal before it completes → the result remains available to copy, but nothing is typed into Terminal.
8. Select a quotation in Safari → **Copy with Source** → paste a Markdown quotation with its page title and URL.

---

## 5. Product principles

1. **Invisible until useful.** Automatic appearance never steals focus or blocks typing. Only explicitly opened interactive surfaces may take keyboard focus, and they return it deliberately.
2. **Never lose the user's data.** Temporary clipboard use must not overwrite a newer copy. Restore only while ownership is provable; otherwise preserve the newer state. Clipboard-manager suppression is tested interoperability, not a universal guarantee.
3. **Fast or absent.** If the selection cannot be read quickly, do not show a late bar.
4. **Compatibility first.** When PopClip's documented behaviour and our preference differ, match PopClip unless there is a safety reason not to.
5. **Built-ins are extensions.** The eight built-in actions ship as bundled extensions, so the platform is proven by the app itself.
6. **Safe by default.** Every installation route shows capabilities. Sensitive capabilities require explicit consent regardless of signature; signing establishes provenance, not harmlessness.

---

## 6. Release phases

| Phase | Contents | Priority covered |
|---|---|---|
| M0 Spikes | Selection detection across the app matrix, panel above fullscreen apps, event tap and permissions, JavaScript sandbox in a helper process | — |
| M1 Core bar | Auto-appear, built-in actions, basic settings, app exclusions and hard blocks, pause, keyboard access, clipboard ownership and safe action lifecycle | P0 |
| M2 Extension runtime 1 | Snippets and packages, the six non-JavaScript action types, options UI, icons, capability consent and identity-safe install flows | P0 |
| M3 JavaScript runtime | Full JS/TS API, modules, network, dynamic actions, external scripts, auth, native rich-result and input-prompt APIs | P1 |
| M4 Selection-first and parity UX | Searchable palette, rich results, per-app action sets, input prompts, folders, separators, pages, instances, icon picker, website privacy rules, sync, configuration portability, no-code actions, scripting and localization | P1 |
| M5 Ecosystem | Directory backend and website, publishing pipeline, signing, atomic updates and rollback, safe mode, one-click install, verified launch workflows including Copy with Source | P1 |
| M6 Beta to 1.0 | Compatibility corpus, app matrix hardening, onboarding, licensing, docs | P1 |
| Post-1.0 | P2 items in §10, including streaming results and bounded action chains | P2 |

---

## 7. App requirements

### 7.1 Activation and selection detection

| ID | Requirement | Pri |
|---|---|---|
| ACT-1 | With "Appear automatically" on, the bar appears after a pointer selection made by dragging, double-click (and double-click-drag), triple-click (and triple-click-drag), or click followed by Shift-click. | P0 |
| ACT-2 | The bar waits for mouse release before appearing, including during double- or triple-click-and-hold. | P0 |
| ACT-3 | A long press of 0.5 s in an editable text area shows the bar with no selection, so Paste is reachable. A double-click or Shift-click in an empty text field does the same. | P0 |
| ACT-4 | A single click in the address bar of a supported browser shows the bar. | P1 |
| ACT-5 | A user-defined global shortcut shows actions for the current selection. It works when "Appear automatically" is off and inside appearance-excluded apps/websites, but never overrides secure input, hard privacy blocks or pause (ACT-17/18). The shortcut must include ⌃, ⌥ or ⌘, or be a bare function key. | P0 |
| ACT-6 | The shortcut opens keyboard mode (BAR-9) in the first usable build. In 1.0 it opens the searchable palette (BAR-16) by default; users may choose the compact keyboard bar instead. | P0 (keyboard mode), P1 (palette) |
| ACT-7 | Holding ⌘ while selecting suppresses the bar for that selection. | P0 |
| ACT-8 | Keyboard-only selections (Shift+arrows) do not trigger auto-appear. | P0 |
| ACT-9 | The selection is read through a strategy chain, stopping at the first success: (1) Accessibility attributes of the focused element; (2) WebKit text-marker attributes; (3) per-app enabling of the Accessibility tree for Chromium and Electron apps, toggled narrowly to avoid window-animation side effects; (4) AppleScript for browsers that need it; (5) simulated ⌘C with clipboard save and restore. | P0 |
| ACT-10 | Before simulated ⌘C, the fallback snapshots all pasteboard items and representations; if any cannot be preserved safely, skip the fallback. Serialize temporary clipboard transactions. Use `changeCount` plus transaction state to track ownership; a count change alone does not prove that the simulated copy caused it. Restore only while the temporary state is still attributable to this transaction. Never overwrite an intervening user/app copy or an ambiguous state, and never interpret an unrelated copy as the selection. Mark app-owned writes with `org.nspasteboard.TransientType` and `ConcealedType` where supported and suppress the alert sound where feasible. Verify clipboard-manager interoperability; do not promise that another app's copy write is invisible. | P0 |
| ACT-11 | Each app has a detection policy (strategy order, whether auto-appear is allowed, known quirks) shipped as data and updatable without an app release. | P1 |
| ACT-12 | The bar never appears, and the selection is never read, for secure text fields or while secure input is active. | P0 |
| ACT-13 | Selections of up to 10 million characters are handled without hanging. Expensive analysis is skipped or bounded for very large selections. | P1 |
| ACT-14 | Do not depend on cursor shape alone to decide that text was selected. It may be one signal among several. | P0 |
| ACT-15 | The event tap is health-checked and reinstalled if macOS disables it. | P0 |
| ACT-16 | A newer selection, focus/context change, privacy-state change or deadline invalidates pending detection work. Late completions cannot show a stale bar, supply stale action input or restore over a newer clipboard write. Delayed synthetic-copy responses and timeout cleanup obey ACT-10. | P0 |
| ACT-17 | **Never read text here** is a hard privacy rule, distinct from appearance exclusions. App rules apply before any selection read and to automatic, hotkey and scripted activation. Website rules use available page metadata before reading text; if website hard blocks are configured and the current browser URL cannot be established, selection access in that browser is blocked with an explanation. Secure input always blocks access. Precedence: secure input/hard block/pause, then activation mode, then action filtering. | P0 (apps and precedence), P1 (websites) |
| ACT-18 | Menu-bar Pause offers **For one hour**, **Until resumed**, and **Resume**. While paused, do not capture selections or start actions through any activation route; cancel pending reads/actions under RUN-3. Hotkeys explain the paused state without reading text. Persist pause across relaunch, use an absolute expiry for timed pause, and show its state in the menu. | P0 |

### 7.2 The bar

| ID | Requirement | Pri |
|---|---|---|
| BAR-1 | The automatically appearing bar is a non-activating floating panel: it never takes focus from the app underneath. An explicitly opened palette, input prompt or interactive result panel may take keyboard focus. On close, restore focus to the originating app/control only if it remains valid and the user has not switched elsewhere; never reactivate it merely because background work finished. | P0 |
| BAR-2 | It appears on the display that contains the selection, above fullscreen apps, in every Space and under Stage Manager. It is clamped to the visible frame of that display. *(PopClip's behaviour here is undocumented; this is our own specification.)* | P0 |
| BAR-3 | Position: a "Position" setting of Above Text or Below Text applies to single-line selections. For multi-line selections the bar appears below the pointer if the user dragged downwards and above the selection if they dragged upwards. When selection bounds are unknown, the pointer location is used. | P0 |
| BAR-4 | An action may ask to be the primary button, centred under the pointer when the bar appears (`wantsPrimaryDisplay`; Copy and Paste use it). | P1 |
| BAR-5 | The bar grows to use available screen width, capped on very wide displays. Overflow goes to further pages through a "More (Page n of m)" button. A Page Break separator forces a split. | P1 |
| BAR-6 | Each action shows as an icon or as text, per action. Hovering shows the action name as a tooltip. | P0 |
| BAR-7 | Folders appear as buttons that open a submenu on hover. An action that has its own behaviour and also a submenu opens the submenu on secondary click. Submenus nest. A submenu can replace the bar content with a back button (as Spelling does). | P1 |
| BAR-8 | Appearance: vibrancy background, a small callout arrow towards the selection, highlight in the system accent colour, Light, Dark, Auto and Auto (Inverse) colour modes, and a size slider with live preview. | P0 (basic), P1 (all modes) |
| BAR-9 | Compact keyboard mode: ← and → move between actions, Return runs the highlighted action, Esc or any other key dismisses; ↑ and ↓ enter and leave folders when folders ship. Navigation keys are consumed, not sent to the source app. Tooltips show during navigation. | P0 (basic), P1 (folders) |
| BAR-10 | Passive bar dismissal has no timer: outside click, an ordinary key (passed through), pointer departure or scroll dismisses it. BAR-9 navigation keys are exempt. Explicitly opened palettes, prompts and result panels use their own focus/keyboard rules and do not dismiss merely because the pointer leaves or the user scrolls their contents. | P0 |
| BAR-11 | Modifier keys held at click time (⇧ ⌃ ⌥ ⌘) are captured and passed to the action. | P0 |
| BAR-12 | Feedback states: a spinner while an action runs; cancellation through the spinner or keyboard obeys RUN-3; "Copied" confirmation; a tick for success; a shaking X for failure. Legacy compact result text is truncated to 160 characters and may offer click-to-paste subject to RUN-2. Native rich results use BAR-17 without changing legacy `after` semantics. | P0 (tick, X, Copied, safe cancellation), P1 (other feedback and previews) |
| BAR-13 | Extension load errors and messages such as "App is excluded" display in the bar itself. | P1 |
| BAR-14 | The bar and every shipped interactive surface expose names, labelled controls, focus order and status changes to VoiceOver, support keyboard operation, and respect Reduce Motion, Reduce Transparency and Increase Contrast. Later surfaces inherit this baseline when introduced. | P0 |
| BAR-15 | A hidden "screenshot mode" preference keeps the bar on screen for taking screenshots. | P2 |
| BAR-16 | **Searchable palette:** the hotkey opens a search field over enabled, context-eligible actions. Search action and extension names without executing them; include folder paths and instance names to disambiguate. Arrow keys navigate, Return runs, Esc closes. Empty queries follow the user's action order; equal search matches keep that order. Typing stays in the palette, not the source app. Search does not expand into a general-purpose launcher. | P1 |
| BAR-17 | **Rich result panel:** multiline, selectable text with safe Markdown rendering and **Copy**, **Replace Selection**, **Insert**, and Close controls. No script execution or automatic remote-content fetches. Opening links requires an explicit user action. Replace uses the verified original selection; Insert uses its end without deleting it. Both require an editable, verified destination under RUN-2 and are disabled when unavailable. Copy remains available. Completed results do not steal focus if the user has moved elsewhere. Streaming is P2. | P1 |

### 7.3 Content analysis and action filtering

| ID | Requirement | Pri |
|---|---|---|
| FLT-1 | Only actions relevant to the current selection and context are shown. | P0 |
| FLT-2 | The analyser detects: web URLs (http and https), scheme-less domains including newer TLDs (normalised by adding `https://`), other URL schemes, email addresses, and local file paths that exist on disk (with `~` and `..` expanded). Each detection records its ranges in the text. | P0 |
| FLT-3 | The context records: app name and bundle identifier, whether Cut, Copy and Paste are available, whether the control supports formatting, and the browser page URL and title where the browser supports it. | P0 |
| FLT-4 | HTML, RTF and Markdown forms of the selection are captured only when a visible action asks for them. The HTML fallback chain is: HTML source, then RTF converted to HTML, then plain text converted to HTML. Markdown is generated from the HTML. Sanitised and raw HTML are both available. | P1 |
| FLT-5 | Each action is filtered by its `requirements`, `regex`, `requiredApps`, `excludedApps` and option-value conditions, in the order defined in §8.5. | P0 |
| FLT-6 | Read-only text never offers Cut or Paste, including read-only web content in Chromium browsers. | P0 |

### 7.4 Built-in actions

There are exactly eight. Each ships as a bundled extension and can be disabled, deleted, renamed, re-iconed, moved, duplicated and restored. Their source is viewable.

| Action | Shown when | Modifiers | Settings | Pri |
|---|---|---|---|---|
| **Cut** | There is a selection and Cut is available | ⇧ plain text only | — | P0 |
| **Copy** | There is a selection | ⇧ plain text only | — | P0 |
| **Paste** | The clipboard has text and Paste is available | ⇧ paste as plain text | — | P0 |
| **Search** | There is text, up to a maximum length. Also shown alongside Open Link unless the selection is only a URL | ⇧ open in a background tab; ⌥ wrap the term in double quotes | Search engine preset, or a custom URL with `***` as placeholder | P0 |
| **Open Link** | The text contains one or more URLs | ⇧ background tab; ⌥ copy the URLs as a list | — | P0 |
| **Dictionary** | The selection is a word found in an enabled macOS dictionary | ⇧ copy the definition | — | P1 |
| **Reveal in Finder** | The selection is an existing file or folder path (a folder opens directly) | — | — | P1 |
| **Spelling** | One misspelled word with suggestions, in editable text | ⇧ copy the suggestion instead of replacing | Up to two languages | P1 |

Details:

- **Search presets:** Baidu, Bing, Brave, DuckDuckGo, Ecosia, Google (default), Kagi, NAVER, Startpage, Yahoo, Yahoo Japan, Yandex.
- **Open Link** opens multiple URLs in separate tabs. It also handles single instances of app URL schemes such as `bluesky:`, `craftdocs:`, `evernote:`, `ftp:`, `hook:`, `message:`, `omnifocus:`, `spotify:`, `x-devonthink-item:` and `lt:`. The scheme list is data, not code.
- **Browser behaviour:** searches and links open in the current app if it is a known browser, otherwise in the default browser. In browsers with tab control, new tabs open next to the current tab.
- **Pasted text** stays on the clipboard by default. A preference restores the previous clipboard instead, subject to ACT-10 ownership checks; a newer user/app copy always wins.

### 7.5 Settings

**Menu bar item** (P0): "Appear automatically" toggle, Pause/Resume and pause status (ACT-18), "Settings…" (⌘,), "Quit". Snippet files and selected snippet text can be dragged onto the icon to install them (P1). The icon can be hidden; relaunching the app from Finder reopens Settings.

**Settings window** (standalone window, three tabs; ⌘W closes).

| Tab | Contents | Pri |
|---|---|---|
| **General** | "Appear automatically"; Rules (Apps…, Websites…) separating appearance exclusions from **Never read text here**; shortcut recorder and compact-bar/palette choice; Appearance (Size, Colour, Position); Accessibility-permission banner | P0 (core and app hard blocks), P1 (website rules and palette choice) |
| **Actions** | Action list (§7.6); search (⌘F); "+" menu with New Action, New Folder (⌘N), New Separator (⌥⌘N); per-app action sets; Get Extensions; Tools menu with Manage Extensions… (⌘E), iCloud Sync and Export/Import Configuration | P0 (list), P1 (rest) |
| **App** | Version and links (website, source code, issue tracker, sponsor); Software Update (check now, Off / Notify only / Install automatically, include betas); Start at login; Show in menu bar; Debug Console. There is no licence or trial section | P1 |

**Rules** (P0 for app exclusions/hard blocks; P1 for the remaining controls):

- **Apps:** automatic-appearance mode is either "Exclude these apps" or "Include only these apps", with a picker of recently used apps. P1 adds explicit per-app **Automatic**, **Hotkey only**, and **Off — never read text** choices. Automatic still respects the global automatic-appearance toggle; Off creates a hard block.
- **Websites:** separate appearance-exclusion and hard-block lists. Rule types are Domain (and subdomains), Host, Starts with, and Other (pattern). Invalid entries are flagged. Page metadata is required; unavailable metadata is explained, and hard blocks fail closed as specified in ACT-17.
- Appearance exclusions restrict only automatic appearance; the hotkey can override them. Hard blocks, secure input and pause cannot be overridden by hotkeys or scripting.

### 7.6 Action list management

| ID | Requirement | Pri |
|---|---|---|
| ALM-1 | There is no limit on the number of actions. | P0 |
| ALM-2 | Per-action commands: Enabled (space bar toggles), Rename (double-click), Change Icon / Reset Icon, Duplicate, Show As (Icon or Text), Colour (15 named colours), Delete, and an Extension submenu with Extension Info and View Source. | P1 |
| ALM-3 | Reordering by drag and drop, including into and out of nested folders. ⌘X, ⌘C, ⌘V and "Move Item Here" (⌥⌘V) work. Undo and redo work. | P1 |
| ALM-4 | Folders, and separators in two styles: Section Break and Page Break. | P1 |
| ALM-5 | Multiple instances of one extension, each with its own name, icon and option values. Duplicate creates an instance. | P1 |
| ALM-6 | A gear button opens a per-action settings sheet generated from the extension's options (§8.9). With no options it says so. | P0 |
| ALM-7 | A newly installed action is highlighted in the list. | P2 |
| ALM-8 | **Per-app action sets:** explicitly show or hide installed action instances by app. Inherit the global user-defined order; no usage-based reordering. App rules can hide an action but cannot enable a globally disabled action, grant capabilities or bypass context requirements/privacy blocks. The palette and bar use the same effective set. Per-app overrides stay local with app rules. | P1 |
| ALM-9 | **New Action** creates a native snippet from a search-URL, open-URL or existing macOS Shortcut template. Provide labelled fields, escaped placeholders, a non-executing input/output preview and a capability summary; any test run is explicit. Saving/installing follows normal identity and consent rules. No new scripting language or arbitrary workflow editor. | P1 |

### 7.7 Icon picker

P1. Three tabs:

- **Search** — searches the Iconify library, with an option to include coloured icons.
- **Text** — one to three characters, with shape (circle or square), fill, regular or monospaced font, and strike-through.
- **Custom** — an icon specifier string, or a chosen or dropped SVG or PNG file.

An Adjust panel offers scale, move X and Y, rotate and flip. The picker also opens standalone with a shortcut (⌥⌘I) so extension authors can compose specifiers.

### 7.8 Extension management

| ID | Requirement | Pri |
|---|---|---|
| EXM-1 | Install by opening a package (`.pappuext`, `.pappuextz`, `.popclipext`, `.popclipextz`) or a snippet file (`.pappucliptxt`, `.popcliptxt`). Zipped packages are deleted after install. | P0 |
| EXM-2 | Install by selecting snippet text: the bar offers **Install Extension "Name"**. The limit is 5,000 characters, and over the limit the bar says so. A matching name alone never silently replaces an extension. A matching identifier with the same trusted provenance offers an explicit replacement for manual installs; a collision from another or unverifiable origin requires a separate install with a new local identity, or explicit approval of a trust transition under SEC-8. | P0 |
| EXM-3 | Install `.js`, `.ts` and `.yaml` snippet files with "Open With" or by dropping them on the menu bar icon. | P1 |
| EXM-4 | PappuClip registers as an alternate handler, not the default owner, for PopClip's file types, so it coexists with an installed PopClip. | P1 |
| EXM-5 | Every install route (directory, file, selected snippet, import, generated action or sync) presents the extension's origin and effective capabilities in plain language. Sensitive capabilities require explicit approval regardless of signature, defaulting to "Don't Allow"; low-risk installs still require an installation confirmation. Summaries cover selection transmission through URLs/network APIs, synthetic input, Services, Shortcuts, scripts and controlled apps, not merely declared entitlements. External scripts and delegated automation may act outside the JavaScript sandbox; say so. Updates use §9.4. | P0 |
| EXM-6 | Manage Extensions sheet: a list sortable by name or date; per-extension Extension Info, New Instance, View Source and View Web Page; an Updates menu with "Check for extension updates" and "Update automatically". | P1 |
| EXM-7 | Extension Info shows origin (Built-in, Directory, Snippet, User-generated, Imported from PopClip), version, action types, identifier, instance count, entitlements, and signature status (Verified, Unsigned). | P1 |
| EXM-8 | View Source opens a viewer with Export… and Copy Snippet. | P1 |
| EXM-9 | Deleting all of an extension's actions uninstalls it. Built-in actions can be restored. | P0 |
| EXM-10 | If an extension names an app that is not installed (`app.checkInstalled`), a "Missing App" alert offers a link to the app's website. | P1 |
| EXM-11 | **Import from PopClip:** on first run, if `~/Library/Application Support/PopClip/Extensions` exists, offer to import those extensions and the app-exclusion list. Imported directory extensions are treated as unsigned, so EXM-5 applies. | P1 |
| EXM-12 | Installs and updates are atomic: validate package, identity, signature where applicable, compatibility and grants before activation. Validation, download or interruption failures leave the working version and options intact. Retain a recoverable previous version and matching non-secret configuration snapshot; never activate partially installed code. | P1 |
| EXM-13 | Manage Extensions offers rollback to a retained, compatible, non-revoked version and a per-extension **Pause updates** control. Revalidate trust/capabilities before rollback; do not restore revoked code or erase newer secrets. Revocation checks remain active while updates are paused. Explain any option-schema rollback limitation before proceeding. | P1 |
| EXM-14 | A documented launch-time safe-mode option works without loading third-party extensions. It disables their code and background population while retaining settings, so users can inspect, roll back or remove a broken extension. Exiting safe mode is explicit. | P1 |

### 7.9 Sync

P1. iCloud sync covers installed extensions, the action list layout (folders, separators, names, icons) and per-action option values. Secrets sync through iCloud Keychain unless local-only. General/App settings, app/website rules, per-app action sets and capability grants stay local. Sync is on by default for fresh installs; onboarding explains its scope. Status covers no iCloud account, restricted iCloud and Low Power Mode.

| ID | Requirement | Pri |
|---|---|---|
| SYN-1 | Use stable extension-instance and list-item IDs. Merge independent additions and edits without duplicates; never replace a whole list with one device's snapshot. Deletions propagate as tombstones so an offline device cannot resurrect removed items. | P1 |
| SYN-2 | Merge non-conflicting fields. Concurrent edits to the same field or item order converge deterministically using logical revision and device-ID tie-breaking, not wall-clock time alone; retain the losing non-secret value/order for explicit recovery. Delete wins over a concurrent edit, with the edited non-secret configuration recoverable locally. Surface conflicts and recovery choices instead of silently losing edits. | P1 |
| SYN-3 | Synced packages undergo normal validation and local capability consent before their code loads, including population functions. Grants never sync. Synced secrets are inaccessible until local trust and capability approval; sync cannot transfer secrets to a different identity or bypass revocation. | P1 |
| SYN-4 | Test offline edit/reconnect, concurrent reorder, delete-versus-edit, repeated delivery and a new device receiving an unapproved extension. All devices converge; deletion does not resurrect actions, and unapproved code never executes. | P1 |

### 7.10 Scripting interface

| ID | Requirement | Pri |
|---|---|---|
| SCR-1 | An AppleScript dictionary with: `appear` (works when auto-appear is off; opens compact keyboard mode), readable/writable `enabled`, `show settings` with optional pane, and `show icon picker`. `enabled` controls automatic appearance only; scripting cannot bypass pause, secure input or hard privacy blocks. | P1 |
| SCR-2 | A `pappuclip://` URL scheme for install-from-directory (always confirmed in-app), opening settings, and appearing. Appearance obeys the same privacy and pause precedence as other activation routes. | P1 |

### 7.11 Onboarding and permissions

| ID | Requirement | Pri |
|---|---|---|
| ONB-1 | First run: explain what the app does, request Accessibility permission with a direct link to the right System Settings pane, and detect the grant live. | P0 |
| ONB-2 | A try-it area with sample text, a link, a misspelling and an editable field. | P1 |
| ONB-3 | If the app is not in `/Applications`, offer to move it. | P1 |
| ONB-4 | Detect a lost or stale Accessibility grant (common after macOS upgrades) and guide the user through removing and re-adding the app. | P1 |
| ONB-5 | Automation permission is requested per target app when an AppleScript action first needs it. A denied permission produces a clear alert with a link to System Settings. | P1 |

### 7.12 Localization

P1: all strings externalised; English ships at 1.0; extension names, titles, labels and descriptions accept per-language dictionaries (§8.3). P2: community translations. PopClip ships 19 languages.

### 7.13 Diagnostics

| ID | Requirement | Pri |
|---|---|---|
| DIA-1 | A Debug Console window shows extension `print()` output, load errors and action results. | P1 |
| DIA-2 | A "Why didn't it appear?" inspector shows, for the last selection attempt: the app and its policy, the gesture recognised, each detection strategy tried with its result and timing, and which rule suppressed the bar. | P1 |
| DIA-3 | Opt-in crash reports. No selected text, clipboard content or extension option values are ever included. | P1 |

### 7.14 Action lifecycle and safe text mutation

These rules apply to built-ins, legacy actions, native actions and host API calls. They govern PappuClip-controlled effects; arbitrary scripts, Services and Shortcuts can perform external effects outside these guarantees, which capability consent must disclose.

| ID | Requirement | Pri |
|---|---|---|
| RUN-1 | At invocation, capture an immutable input snapshot plus originating app/process, focused control and selection context. Track changes separately; never silently retarget an in-flight action to the current app. A focus transfer into an explicitly opened PappuClip surface is tracked as such, not mistaken for a new destination. | P0 |
| RUN-2 | Before any host-controlled cut, insertion, replacement or synthetic input, verify the intended destination, editability and relevant selection context. A source edit, changed selection, app switch or unverifiable destination prevents automatic mutation. Present the completed result for explicit copy instead; do not auto-copy as an error fallback over a newer clipboard value. Explicit Replace/Insert controls may return to the origin only after fresh verification; otherwise disable them and explain why. Recheck privacy rules at execution time. | P0 |
| RUN-3 | Cancellation immediately invalidates the invocation, rejects subsequent host-effect requests and discards late results/errors rather than pasting, copying or showing success. Stop owned work where supported; terminate owned script processes where safe and request cancellation of delegated automation. Explain when an external action may already have completed or cannot be stopped. Never promise rollback of external effects. Pause/revocation also invalidate affected invocations. | P0 |
| RUN-4 | Text replacement participates in the target app's native Undo where supported, preferably as one edit. Document unsupported targets; do not implement an unsafe global Undo by replaying stale text. | P0 |
| RUN-5 | Regression scenarios cover slow translation in Notes followed by switching to Terminal, editing the source while a result is pending, changing selection, closing the source window, entering secure input, cancellation immediately before completion and a new selection racing an older detection. Assert no wrong-destination mutation, no late success after cancellation, and no stale bar. | P0 |

### 7.15 Configuration portability

| ID | Requirement | Pri |
|---|---|---|
| CFG-1 | Export a versioned, portable configuration containing action instances/layout, non-secret option values, settings, app/website rules, per-app sets and extension identities/versions. Include local snippet/package content for backup; do not redistribute it through the directory without licence review. Exclude Keychain secrets, auth tokens, password fields and capability grants; this format has no secret-export mode in 1.0. Warn that ordinary text options or embedded scripts may themselves contain user-entered sensitive data. | P1 |
| CFG-2 | Import previews changes, validates the whole archive before applying them and offers merge or explicitly confirmed replacement with a recoverable non-secret snapshot. Preserve active hard privacy blocks unless their removal is separately confirmed. Packages follow normal validation, collision and local approval rules before executing. Unsupported versions fail without changing the current configuration; missing secrets require reauthentication. | P1 |
| CFG-3 | Export/import works offline in official and source-built apps without CloudKit. A round trip preserves layout, rules and non-secret options; it never restores grants or exposes a prior identity's secrets. | P1 |

---

## 8. Extension platform requirements

### 8.1 Compatibility strategy

PappuClip's native extension format **is** PopClip's documented format, plus clearly marked additions. The runtime emulates PopClip API level **6221**.

| Aspect | PopClip form (accepted) | Native form (also accepted) |
|---|---|---|
| Snippet marker | `#popclip`, `# popclip` | `#pappuclip`, `# pappuclip` |
| Package | `Name.popclipext`, `.popclipextz` | `Name.pappuext`, `.pappuextz` |
| Snippet file | `.popcliptxt` | `.pappucliptxt` |
| JavaScript global | `popclip` | `pappuclip` (the same object) |
| Script variables | `POPCLIP_*` | `PAPPUCLIP_*` (both always set) |
| AppleScript and URL placeholders | `{popclip text}` | `{pappuclip text}` |
| Minimum version key | `popclipVersion` (PopClip build number) | `pappuclipVersion` (our build number) |

Rules:

- If `popclipVersion` is higher than the emulated level, loading fails with a message that says which API level is needed. A debug preference overrides this.
- Additions use native-only keys/methods and are opt-in. Legacy behaviour is preserved except for explicit safety exceptions: capability consent, identity-bound secrets, privacy blocks, clipboard ownership, destination validation and execution budgets. Document those exceptions in the compatibility guide and conformance results.
- PopClip's documented backward-compatibility behaviour is reproduced, for example the `/bin/sh` default for shell files when `popclipVersion` is below 4035.

### 8.2 Extension forms

| ID | Requirement | Pri |
|---|---|---|
| FMT-1 | **Config snippets:** plain text whose first line is the marker (extra text may follow on that line). The body is YAML 1.2; flow YAML and JSON are accepted; tabs are not valid indentation. | P0 |
| FMT-2 | **Code snippets:** the config is a run of comment lines starting at the marker, and the whole text is also the script. `//` headers mean TypeScript unless `language: javascript`; `--` means AppleScript; `#` means shell and needs `interpreter` or a `#!` line before the marker. A JavaScript body that exports or calls `defineExtension()` loads as a module. | P1 |
| FMT-3 | Snippets cannot reference other files, so their icons must be text, Iconify, SF Symbol, `svg:` or `data:` forms. With no `identifier`, the `name` acts as the manifest identifier, not proof of trust or permission to overwrite an installed extension (EXM-2). | P0 |
| FMT-4 | **Packages:** a folder with exactly one config file in its root, base name `Config` (case-sensitive): `Config.plist`, `Config.json` (parsed as JSON) or `Config.yaml`; or `Config.js`, `Config.ts`, `Config.applescript`, another extension or a bare `Config`, parsed as a code snippet. Subfolders are allowed. `_Signature.plist` is reserved and ignored. | P0 |
| FMT-5 | **Key normalisation:** `keyName`, `key name`, `Key Name`, `KeyName`, `key_name`, `key-name` and `KEY_NAME` are equivalent. Lowercase and space-separate the words, strip a leading `extension` or `option`, then apply the legacy map (Appendix A). In plist, `<false/>` stands for `null`. | P0 |
| FMT-6 | **Identifiers** may contain `A-Z a-z 0-9 . - _`, must start and end with an alphanumeric character, and may not contain consecutive separators. The prefix `app.pappuclip.` is reserved for extensions signed by our directory. Identifiers with PopClip's reserved prefix `com.pilotmoon.` load normally as local or imported extensions. | P0 |
| FMT-7 | Installed extensions live in `~/Library/Application Support/PappuClip/Extensions`. | P0 |

### 8.3 Config schema

**Top-level keys.** Only `name` is required.

| Key | Type | Meaning |
|---|---|---|
| `name` | Localizable string | Display name |
| `icon` | String | Falls back to the first action's icon |
| `identifier` | String | See FMT-6 |
| `description` | Localizable string | Shown in the directory |
| `keywords` | String | Space-separated, for directory search |
| `macosVersion` | String | Minimum macOS |
| `popclipVersion`, `pappuclipVersion` | Integer | Minimum API level |
| `options` | Array | §8.9 |
| `entitlements` | Array | `network`, `dynamic`, `script`. `dynamic` cannot be combined with the other two |
| `action`, `actions` | Dict, Array | The actions |
| `submenu` | Array | The extension becomes one button that opens a submenu; cannot be combined with `action` or `actions` |
| `showAs` | `icon` or `text` | Default `icon`; the user can override per action |
| `authServiceLabel` | Localizable string | Defaults to the name |
| `authKeychain` | `sync` or `local` | Default `sync` |
| `offersMultipleInstances` | Boolean | Default: true if the extension has options |
| `shellScriptRationale` | String | Ignored by the app; required by the directory for shell actions |
| `module` | String or Boolean | Module file path, or an override for module detection |
| `language` | `javascript`, `typescript`, `applescript` | For snippets |
| `app`, `apps` | Dict, Array | `name`, `link`, `checkInstalled`, `bundleIdentifiers` |
| `replaces` | String | Native-only predecessor identifier for a reviewed migration; never sufficient by itself to transfer ownership, grants or secrets (SEC-8) |

A localizable string is either a plain string or a dictionary keyed by language code with `en` required. Action keys at top level act as defaults for the entries in `actions`. A module cannot set `name`, `icon`, `identifier`, the version keys, `entitlements`, `module`, `showAs` or `offersMultipleInstances`.

**Action keys.**

| Key | Default | Meaning |
|---|---|---|
| `title` | Extension name | Localizable |
| `icon` | — | `null` means explicitly no icon |
| `identifier` | — | Passed to scripts |
| `requirements` | `[text]` | §8.5. `[]` means none |
| `regex` | — | ICU syntax; in a module it may be a JS `RegExp` |
| `requiredApps`, `excludedApps` | — | Bundle identifiers |
| `before`, `after` | — | §8.6 |
| `stayVisible` | false | Keep the bar up after the action |
| `captureHtml` | false | Capture HTML and Markdown |
| `captureRtf` | false | Capture RTF |
| `restorePasteboard` | false | Applies to `paste-result` |
| `submenu` | — | Array, or a function in modules; nestable |
| `wantsPrimaryDisplay` | false | BAR-4 |
| `wantsInitialDisplay` | false | The submenu is open when the bar appears |
| `separator` | — | Submenu entries only |
| `pappuAfter` | — | Native-only `rich-result` presents a returned string in BAR-17 as plain text; mutually exclusive with `after`. P1 |

### 8.4 Action types

| Type | Keys | Input and output | Pri |
|---|---|---|---|
| **URL** | `url`, `cleanQuery`, `spacesAsPlus` | Placeholders `{popclip text}`, `***`, `{popclip option <id>}`. Text is trimmed and URL-encoded. ⌥ quotes the query. ⇧ opens in a background tab. No output. `alternateUrl` is ignored. | P0 |
| **Key Press** | `keyCombo`, `keyCombos` (entries may be `wait <ms>`), `keyComboTarget` (`session`, `app`, `hid`) | Format `<modifiers> <key>`. Modifiers: `command`/`cmd`, `option`/`opt`, `control`/`ctrl`, `shift`, `numpad`. Key: a character, a name (`return`, `space`, `delete`, `escape`, arrows, `f1`–`f20`), or a hex virtual key code (the Carbon `kVK_*` values). No input, no output. | P0 |
| **Service** | `serviceName` | The macOS Service's menu name. Text (and HTML with `captureHtml`) goes on a private pasteboard, so the general clipboard is untouched. No output. | P0 |
| **Shortcut** | `shortcutName` | Text in; returned text goes to `after`. Runs without bringing the Shortcuts app forward, with a cancel path if the shortcut prompts. | P0 |
| **AppleScript** | `appleScript`, `appleScriptFile` (`.applescript`, `.scpt`), `appleScriptCall` (`handler`, `parameters`) | Plain-text scripts use placeholders; compiled scripts use a handler. A returned string goes to `after`. Error number 502 opens the settings sheet. | P0 |
| **Shell Script** | `shellScript`, `shellScriptFile`, `interpreter`, `stdin`, `shellMode` (`login` default, `nonlogin`, `none`) | Variables in §8.7. Working directory is the package. stdout goes to `after`. Exit 0 success; exit 2 opens settings; other codes fail. File execution rules match PopClip's (interpreter given; else executable with `#!`; else `/bin/sh` for `.sh` or old API levels; else a load error). | P0 |
| **JavaScript / TypeScript** | `javaScript`, `javaScriptFile`, or `module` | §8.8 | P1 |

### 8.5 Matching pipeline

Before this pipeline, privacy/pause checks must permit selection access and the extension must have local execution approval. Global enablement and per-app action visibility (ALM-8) can only restrict the result; they never override the extension's requirements.

1. App filters (`requiredApps`, `excludedApps`) and option-value conditions are checked.
2. Each entry in `requirements` must hold. A `!` prefix negates an entry. Values: `text` (synonym `copy`), `cut`, `paste`, `url`, `isurl`, `urls`, `email`, `emails`, `path`, `formatting`, `option-<id>=<value>` (booleans as `1` and `0`). Legacy `httpurl` and `httpurls` map to `url` and `urls`.
3. `url`, `isurl`, `email` and `path` narrow and normalise the text passed to the action.
4. `regex` is applied to the narrowed text, and the match becomes the input text. Capture groups are available to JavaScript.
5. The full selection always remains available (`POPCLIP_FULL_TEXT`, `popclip.input.text`). The narrowed text is `POPCLIP_TEXT` and `popclip.input.matchedText`.

### 8.6 `before` and `after`

| Value | Step | Effect |
|---|---|---|
| `cut`, `copy`, `paste`, `paste-plain` | both | Performs that command |
| `copy-result` | after | Copies the result and shows "Copied" |
| `paste-result` | after | Pastes if the original destination remains verified and Paste is available; if Paste was unavailable at invocation, copies as in PopClip. A stale/unsafe destination follows RUN-2 instead of silently pasting or copying |
| `preview-result` | after | Copies the result and shows it truncated to 160 characters; clicking pastes only after destination verification |
| `show-result` | after | Copies the result and shows it truncated |
| `show-status` | after | Shows a tick or an X |
| `popclip-appear` | after | The bar reappears |
| `copy-selection` | after | Copies the original selection |

All legacy steps obey RUN-1–4, including cancellation before clipboard writes. The native `pappuAfter: rich-result` key presents the returned string without copying or mutating text automatically; it does not redefine any legacy `after` value. Rich Markdown uses JS-17.

### 8.7 Script variables

Set for shell scripts as environment variables and for AppleScript as `{popclip …}` placeholders: `TEXT`, `FULL_TEXT`, `URLENCODED_TEXT`, `HTML` (sanitised), `RAW_HTML`, `MARKDOWN`, `URLS` (newline-separated), `MODIFIER_FLAGS` (shift 131072, control 262144, option 524288, command 1048576, summed), `BUNDLE_IDENTIFIER`, `APP_NAME`, `BROWSER_TITLE`, `BROWSER_URL`, `EXTENSION_IDENTIFIER`, `ACTION_IDENTIFIER`, and `OPTION_<ID>` for each option. All values are strings; missing values are empty. `POPCLIP_EMAILS` and `POPCLIP_PATHS` are also set for older extensions *(unverified for the current PopClip build)*.

### 8.8 JavaScript runtime

| ID | Requirement | Pri |
|---|---|---|
| JS-1 | Engine: JavaScriptCore, ES2023 with polyfills for newer built-ins. There is no `fetch`, DOM, `process` or filesystem access. `print()` writes to the Debug Console. | P1 |
| JS-2 | Globals: `popclip`, `pappuclip`, `util`, `pasteboard`, `$`, `print`, `sleep`, `defineExtension`, `RichString`, `require`, `module`, `exports`, `define`, `Buffer`, `URL`, `URLSearchParams`, `XMLHttpRequest`, `structuredClone`, timers, `Blob`, `TextEncoder`, `atob`, `btoa`, `window`. | P1 |
| JS-3 | `popclip` read-only state: `modifiers`; `input` (`text`, `matchedText`, `regexResult`, `html`, `xhtml`, `markdown`, `rtf`, `content`, `isUrl`, `data.urls`, `data.nonHttpUrls`, `data.emails`, `data.paths`, each with ranges); `context` (`hasFormatting`, `canPaste`, `canCopy`, `canCut`, `browserUrl`, `browserTitle`, `appName`, `appIdentifier`); `options` including `authsecret`. | P1 |
| JS-4 | `popclip` methods: `pasteText`, `pasteContent`, `copyText`, `copyContent`, `performCommand`, `showText` (compact or large style, optional preview), `showSuccess`, `showFailure`, `showSettings`, `appear`, `pressKey`, `pressKeys`, `performService`, `revealFile`, `openUrl`, `openTemplateUrl`, `share`, `signInRequiredError`, `settingsRequiredError`. | P1 |
| JS-5 | External scripts, requiring the `script` entitlement: `runAppleScript`, `runAppleScriptFile`, `runShortcut`, `runShellScript`, `runShellScriptFile`, and the `$` shell template tag (zsh with `set -euo pipefail`, interpolated values shell-escaped). From JavaScript the default `shellMode` is `none` with a minimal `PATH`. A non-zero exit rejects with `status`, `stdout`, `stderr` and `terminationReason`. | P1 |
| JS-6 | `util`: dictionary and spelling functions, `localeInfo`, `timeZoneInfo`, `htmlToMarkdown`, `cleanHtml`, Base64, query building and parsing, random values and UUIDs, `hash` and `hmac` (md5, sha1, sha224, sha256, sha384, sha512), `clarify`, and key and modifier constants. | P1 |
| JS-7 | `pasteboard.text` and `pasteboard.content` (plain text, HTML, RTF). `RichString` converts between RTF, HTML and Markdown. | P1 |
| JS-8 | Network: `XMLHttpRequest` works only with the `network` entitlement. Named hosts must use https; plain http is allowed for localhost, numeric IPs, unqualified names and `.local`. | P1 |
| JS-9 | Bundled libraries available to `require`, at the same major versions as PopClip: axios, buffer, case-anything, content-type, dom-serializer, emoji-regex, entities, fast-json-stable-stringify, fast-plist, htmlparser2, js-yaml, linkedom, linkifyjs, oauth-1.0a, rot13-cipher, sanitize-html, sucrase, turndown, valibot. All are permissively licensed; confirm each licence before bundling. | P1 |
| JS-10 | Module resolution: `./` and `../` are relative to the current file; other specifiers try the package root and then the bundled libraries; absolute paths and paths escaping the package are invalid; `.js`, `.ts` and `.json` are supported; results are cached. `import` and `export` are converted to `require`. | P1 |
| JS-11 | Inline and file scripts are wrapped in an async function. A returned string goes to `after`. A thrown error shows failure. An error message starting with `settings error` or `not signed in` opens the settings sheet. | P1 |
| JS-12 | Module extensions export through `defineExtension(obj)`, a default export, named exports or CommonJS. Fields: `options`, `auth`, `actions` (array or population function), `action`, `submenu`, `test`. Module actions use `code`; an action may be a bare function. | P1 |
| JS-13 | Population functions need the `dynamic` entitlement and run each time the bar appears. During population there is no network, no `popclip` methods, no timers and no access to secrets. | P1 |
| JS-14 | TypeScript files are transpiled at load time with no type checking. | P1 |
| JS-15 | The bar shows a spinner while asynchronous work runs, with mouse and keyboard cancellation. Cancellation invalidates the invocation and its outstanding host calls under RUN-3, even if a promise resolves later. | P1 |
| JS-16 | **Safety addition:** population shares the end-to-end deadline in §11.1. Initial ceiling: 15 ms per function and 30 ms aggregate, also capped by the time remaining before rendering must start. Count helper startup and IPC in the same deadline; skip work that cannot fit, discard late results, and report the omission/timing without selection content. Never move visible buttons when late population completes. PopClip documents no limit. | P1 |
| JS-17 | **Native addition:** `pappuclip.showResult(text, { format })`, where `format` is `text` (default) or `markdown`, presents BAR-17 without an implicit clipboard write. The panel retains the invocation's destination context and obeys cancellation, safe rendering and focus rules. This does not change legacy `showText`. | P1 |
| JS-18 | **Native addition:** `await pappuclip.promptText({ label, placeholder, defaultValue })` opens one labelled text field with Submit/Cancel during an explicitly invoked action, never during population. `label` is required; the other strings are optional. Submit resolves to the entered string (including empty); Cancel, Esc or close cancels the invocation under RUN-3. No arbitrary HTML/UI, secret-field use or automatic persistence. The prompt is keyboard/VoiceOver accessible; after submission, any result mutation still revalidates the original destination. | P1 |

### 8.9 Options

| Key | Notes |
|---|---|
| `identifier` | Required. It is the storage key, so renaming it loses the saved value |
| `type` | Required: `string`, `boolean`, `multiple`, `secret` (Keychain), `password` (never stored; passed only to `auth`), `heading` |
| `label`, `description` | Localizable. URLs and Markdown links in descriptions are clickable |
| `defaultValue` | `string` defaults to empty, `boolean` to true, `multiple` to the first value. A `secret` has no default |
| `values`, `valueLabels` | For `multiple` |
| `multiline` | For `string` |
| `allowOther`, `allowNone` | For `multiple` |
| `icon` | For `boolean` |
| `inset` | Indents the row |
| `keychain` | For `secret`: `sync` or `local` |
| `hidden`, `migrateFrom` | Present in PopClip's type definitions only |

Values reach scripts as `POPCLIP_OPTION_<ID>`, `{popclip option <id>}`, `popclip.options.<id>` and the second argument of action functions. Values are stored per instance.

### 8.10 Authentication

P1. A module may export `auth(info, flow)`. `info` carries `username`, `password`, `redirect`, `name` and `identifier`. `flow(url, params, expect)` opens the browser and resolves with the named query parameters received on a local callback listener. The returned secret is stored in the Keychain as `authsecret`. The settings sheet shows Sign In and Sign Out and the signed-in account label. Secret access is scoped to the approved extension identity and instance (SEC-8); replacing an extension, syncing it or declaring `replaces` never transfers secrets implicitly.

### 8.11 Icons

P0 for text, file and SF Symbol icons. P1 for the rest.

- **Base forms:** a `.png` or `.svg` file path (packages only; `file:` prefix when combined with modifiers); text of up to three characters (`text:` prefix optional; a lone emoji renders in colour); `iconify:<set>:<name>` (fetched remotely and cached); `symbol:<SF Symbol name>`; `svg:<svg string>`; `data:` URLs for SVG and PNG.
- **Modifiers**, written before the base form: `square`, `circle`, `search`, `strike`, `filled`, `monospaced`, `flip-x`, `flip-y`, `move-x=`, `move-y=`, `scale=`, `rotate=`, `preserve-color`, `preserve-aspect`. `=0` negates a modifier. Legacy underscore spellings are accepted.
- Icons render monochrome in a square canvas unless told otherwise.
- Iconify lookups go to the Iconify API (or our own proxy), which the privacy policy must state. Fetched icons are cached so the bar works offline.

### 8.12 Security model

The tiers describe execution mechanisms, **not trust levels**. Every installation shows origin and capabilities; a verified signature never substitutes for consent. Sensitive capabilities include sending selection/context outside the app (including URL templates), synthetic input/app control, Services, Shortcuts, network access and external scripts. Sandboxed JavaScript host methods are included in this assessment even without an entitlement.

| Tier | What the extension contains | Install behaviour |
|---|---|---|
| 0 | URL, Key Press, Service or Shortcut actions | Confirm installation; explicitly approve effective sensitive capabilities |
| 1 | Sandboxed JavaScript with no entitlements | Confirm installation; describe accessible host methods and approve sensitive capabilities they expose |
| 2 | JavaScript with `network`, `dynamic` or `script` | Confirm installation; describe entitlements and effective host capabilities; approve sensitive ones |
| 3 | Shell Script or AppleScript actions | Explicit approval with an outside-sandbox warning; directory requires a written shell-action rationale |

| ID | Requirement | Pri |
|---|---|---|
| SEC-1 | JavaScript runs in a separate helper process with no filesystem access. Network access is granted only to extensions with the `network` entitlement. A crash or hang in extension code never takes down the bar. | P1 |
| SEC-2 | Extension code has watchdog limits on run-away CPU and memory. User-initiated actions have no fixed timeout, because the user can cancel them. | P1 |
| SEC-3 | Secrets live only in the Keychain, are never readable during population, and are never written to logs. | P1 |
| SEC-4 | Every installation route shows a plain-language capability summary and requires approval as in EXM-5. Treat signing as provenance, not a safety exemption. Users can inspect/revoke grants in Extension Info; revoking execution approval disables the extension and invalidates its pending host work. | P0 |
| SEC-5 | The app fetches a signed revocation list with its update checks. A revoked extension version is disabled and the user is told why. | P1 |
| SEC-6 | **Native addition:** an optional `networkHosts` list in the manifest. When present, requests to other hosts fail. The directory encourages it. | P2 |
| SEC-7 | Effective capabilities include action types, delegated automation, accessible host methods and known destinations, not just manifest entitlements. For code whose effects cannot be determined, disclose and seek consent for the broader reachable capability rather than claiming a narrow sandbox. Gate host calls against local grants. New or expanded sensitive access requires reapproval; denied access cannot be obtained through another action type. | P0 (non-JS), P1 (JS) |
| SEC-8 | Bind grants and Keychain access to extension identity, instance and trusted provenance, not display name or identifier alone. For directory code, use the signed namespace/publisher ownership record; for local code, retain its approved origin and content digest. An unverified content/provenance change requires approval before execution. A trust transition requires explicit approval; reauthentication is the default. Any secret migration requires separate approval naming source and destination and a reviewed ownership/migration mapping. A package's `replaces` claim alone cannot authorise it. | P0 (install identity), P1 (auth/migration) |

### 8.13 Signing

P1. Extensions published through our directory are signed on the server. The signature covers a manifest of every file's hash plus the identifier and version. Public keys are pinned in the app, and the scheme supports key rotation. The private key never leaves the signing service. The signature file uses its own reserved name so it never collides with PopClip's `_Signature.plist`.

### 8.14 Developer tooling

| ID | Requirement | Pri |
|---|---|---|
| DEV-1 | Debug preferences: verbose extension logging and Safari Web Inspector attachment. A developer may approve a specific local development folder for reload, with a persistent development-mode warning; capability increases still require approval. No global bypass of capability consent, secure input, privacy blocks or destination safety. | P1 |
| DEV-2 | A command-line harness, `pappuclip run <file> [function]`, that runs a module's exported function (by default `test`) and exits 0 or 1. | P1 |
| DEV-3 | Our own TypeScript definitions package, written from the public API documentation. PopClip's `popclip-types` repo has no licence, so it must not be copied. | P1 |
| DEV-4 | A developer documentation site that covers the format and API, including where PappuClip differs from PopClip, plus a template repo. | P1 |
| DEV-5 | A machine-readable docs bundle (`llms.txt`) and an extension-authoring skill for AI coding tools. PopClip ships both. | P2 |
| DEV-6 | Hot reload of a development folder. | P2 |

---

## 9. Ecosystem requirements

### 9.1 Directory website

| ID | Requirement | Pri |
|---|---|---|
| DIR-1 | A public site listing every published extension, with curated categories (start from PopClip's 31, Appendix C), search across name, keywords, associated apps **and description**, and sorting by newest, recently updated and most installed. | P1 |
| DIR-2 | A listing page shows: icon, name, author, description, demo video or GIF, rendered readme, version and dates, identifier, licence, minimum app version, action types and capabilities in plain language, source link pinned to the exact commit, associated apps, previous versions, and an Install button. | P1 |
| DIR-3 | Install opens `pappuclip://install?…`. The app confirms with the user, downloads, verifies the signature and installs. A plain download link is the fallback. | P1 |
| DIR-4 | Author pages, a "Newly Added" section and a featured slot. | P1 |
| DIR-5 | Anonymous install counts, counted on the server from downloads with no user identifiers. | P1 |
| DIR-6 | Ratings and reviews. | P2 |

### 9.2 In-app discovery

| ID | Requirement | Pri |
|---|---|---|
| STORE-1 | "Get Extensions" opens the directory website. | P1 |
| STORE-2 | An in-app browser for the directory with search, categories and one-click install. | P2 |

### 9.3 Publishing pipeline

| ID | Requirement | Pri |
|---|---|---|
| PUB-1 | Authors publish from their own public GitHub repo: install our GitHub App, add `pappuclip-directory.yaml` (`include` globs, optional `exclude` and `versionPrefix`), and push a version tag. | P1 |
| PUB-2 | If our YAML file is absent, `popclip-directory.yaml` is read instead, so an author already publishing to PopClip can dual-publish just by installing our GitHub App. Installing the App is the author's explicit consent. | P1 |
| PUB-3 | Versions are git tags of one to four dot-separated integers, strictly increasing. In a monorepo only changed packages take the new version. | P1 |
| PUB-4 | Automated checks: required fields (`name`, `identifier`, `description`, a minimum version key), identifier never changes, limits of 100 files, 1 MiB per file and 2 MiB in total, no minified or binary content, a licence file present, and `shellScriptRationale` of at least 20 characters for shell actions. Results are posted back as a GitHub check. | P1 |
| PUB-5 | Human review follows the checks: not malicious, does what it says, and uses sandboxed JavaScript where that can do the job. A published review policy and a target turnaround. | P1 |
| PUB-6 | On approval the server signs and publishes. Files starting with `_` or `.`, and the readme and demo media, are stripped from the downloadable package. | P1 |
| PUB-7 | Authors can unpublish. We can unlist, and can revoke in an emergency (SEC-5). | P1 |

### 9.4 Updates

P1. Directory extensions update automatically (user-controllable), using atomic activation and recoverable snapshots (EXM-12). The update check sends only extension identifiers and versions. Show a capability delta and require approval before activating any update that expands effective access: new entitlements/action types, newly controlled apps, wider declared destinations or broader host/delegated automation access (SEC-7). Do not infer safety from an unchanged entitlement array or signature. Until approved, retain the working version unless revoked. Trust changes follow SEC-8. Failed updates leave the current version usable; rollback, pause and revocation follow EXM-13 and SEC-5.

### 9.5 Launch catalogue

- **Source:** the `source/` folder of `pilotmoon/PopClip-Extensions` (about 220 maintained packages), licensed MIT, "Copyright (c) 2012 Nicholas Moore and contributors", "unless stated otherwise in the extension readme files".
- **Process per extension:** check its licence and bundled third-party code; preserve copyright and author credit; assign a new identifier under our namespace with a reviewed `replaces` mapping; offer approved non-secret option migration to switchers. Grants never migrate; secrets follow SEC-8 or require reauthentication. Review third-party logos and run a functional smoke test on the actual distributed package.
- **Skip** extensions for dead services (for example Pocket, Omnivore, Skype).
- **Do not** hotlink, scrape or mirror PopClip's directory downloads. Extensions outside the MIT repo need their own licence check; some have none and cannot be redistributed.
- **Release gate:** cover every required workflow below with reviewed, signed, functionally verified packages. Record tested package version, input/observable outcome, supported dependencies and test date. No launch package is counted as verified on a load-only check, missing credentials or a simulated external-service response.
- **Required workflows:** case conversion and whitespace cleanup; list sorting; Markdown/rich-text conversion; word/character counts; append/swap clipboard; custom web search; translation; JSON formatting and encoding; calculation/unit conversion; one local-model AI action; capture to a notes app; capture to a task app; and Copy with Source. Pick maintained packages by Appendix C priority; these workflows, not every example in the appendix, define the minimum catalogue.
- **Stretch target:** 150 packages. A smaller catalogue that satisfies the workflow and quality gates is sufficient for 1.0; catalogue size must not delay a safe, useful release.

| ID | Requirement | Pri |
|---|---|---|
| CAT-1 | **Copy with Source** ships as a catalogue extension, not a ninth built-in. It copies the selected quotation with available page title/URL as plain text or Markdown, preserving text and escaping Markdown correctly. When metadata is unavailable, clearly offer quotation-only copy without inventing attribution or silently claiming a complete citation. It uses metadata already available through the normal privacy-checked context and makes no background network request. | P1 |

### 9.6 Directory backend

P1. Endpoints: list and search; extension detail; version file download; batch update check; revocation list. It is served from a CDN, and the app works normally when the directory is unreachable. A documented public API is a small differentiator, since PopClip has no list endpoint.

### 9.7 Community

P1: a discussion forum (GitHub Discussions is enough to start) with categories for help, extension sharing and requests; a contribution guide; snippet sharing that works by select-and-install. P2: a showcase of community snippets inside the directory.

---

## 10. Beyond parity

The first four improvements are part of 1.0. Streaming, richer activation controls and the other items remain post-launch; the action palette is selection-first, not a general launcher.

| ID | Differentiator | Scope and priority |
|---|---|---|
| DIF-1 | **Rich result panel** | P1: multiline text/Markdown with Copy, Replace Selection and Insert (BAR-17, JS-17, `pappuAfter`). P2: streaming, retaining the same cancellation and destination-safety rules |
| DIF-2 | **Hybrid activation** | P1: searchable hotkey palette plus per-app Automatic, Hotkey only and Off modes (ACT-6/17, BAR-16). Existing ⌘ suppression stays P0; configurable require/suppress modifiers are P2 |
| DIF-3 | **Input prompt API** | P1: one labelled text field with Submit/Cancel during explicit action execution (JS-18), not arbitrary extension-provided UI |
| DIF-4 | **Per-app action sets** | P1: explicit show/hide overrides with stable global ordering (ALM-8); per-app custom ordering is P2 |
| DIF-5 | **In-place extension editor** with live reload for snippets | P2; the limited no-code action creator (ALM-9) ships at P1 |
| DIF-6 | **AI provider layer:** one configuration for OpenAI-compatible, Anthropic and local (Ollama, Apple on-device) models, with the user's keys | P2; 1.0 extensions configure their own providers |
| DIF-7 | **Browser companion extension** for reliable selection and page metadata | P2 |
| DIF-8 | **OCR fallback** for text that cannot be selected | P2 |
| DIF-9 | **Team features:** managed extension sets and configuration profiles | P2 |
| DIF-10 | **Bounded action chains** | P2: explicitly ordered transformations such as trim → format → copy. Show combined capabilities before approval, pass each result to the next step, stop on failure/cancellation and never automatically retry a side-effecting step. Apply normal privacy/destination checks; no branching workflow editor or promise to undo completed external effects |

---

## 11. Non-functional requirements

### 11.1 Performance

- End-to-end latency targets remain ≤ 150 ms p95 on Accessibility and ≤ 350 ms p95 on clipboard fallback (§3.3). Initial shared budgets below sum to those limits; M0 measurements may redistribute stages but may not increase the total without revising the release target. A fallback attempt inherits elapsed time from earlier strategies rather than starting a new timer.

| Stage | Accessibility path | Clipboard fallback path |
|---|---|---|
| Gesture dispatch, privacy/context checks and selection read | 70 ms | 270 ms, including earlier strategy attempts and safe clipboard cleanup |
| Bounded analysis and static filtering | 20 ms | 20 ms |
| Dynamic population, helper startup and IPC | 30 ms aggregate, ≤ 15 ms per function | 30 ms aggregate, ≤ 15 ms per function |
| Layout and first visible frame | 30 ms | 30 ms |

- Use one monotonic deadline per selection attempt. Reserve rendering time; shorten/skip population when upstream work consumes its allocation. Never show a late bar if the deadline cannot be met. Report skipped dynamic actions so a fast but incomplete bar cannot masquerade as successful compatibility. Measure cold and warm paths separately.
- No polling; all detection is event-driven.
- Memory under 80 MB resident with 50 extensions installed.
- Ready within one second of launching at login.
- Extension configs are parsed once and cached. JavaScript contexts are created lazily.

### 11.2 Reliability

- Extension crashes are isolated from the bar (SEC-1).
- Clipboard fallback restores only while it owns the temporary state (ACT-10). A newer user/app write always wins; ambiguous ownership aborts the read without destructive restoration. Cover delayed copies, timeouts, overlapping reads, rich text, images, unpreservable representations and clipboard-manager interference.
- The event tap is monitored and reinstalled (ACT-15).
- A failed or slow selection read shows nothing; it never shows a stale bar.
- Asynchronous results, cancellation and synthetic input obey RUN-1–5; app switching or source edits never silently retarget an action.
- Atomic install/update, rollback to a non-revoked version, safe mode and sync conflict recovery are release acceptance scenarios, not optional support procedures.

### 11.3 Privacy

- Selected text leaves the Mac only through an explicitly invoked action with approved effective capabilities. Explain URL-based transmission and delegated automation as well as direct network requests.
- No analytics on selections, clipboard content, app usage or option values.
- Update checks carry the app version, macOS version and extension versions, and no persistent user identifier.
- The privacy policy discloses every network endpoint: updates, directory, icon lookups, crash reports.
- Hard privacy blocks, secure input and pause take precedence over all activation routes, including scripts. Unknown browser URLs fail closed when website hard blocks apply (ACT-17).
- Export archives contain no app-managed secrets or grants; disclose potentially sensitive ordinary option/script content (CFG-1). Test/diagnostic exports never include real selection or clipboard content.

### 11.4 Security

- Developer ID signing, hardened runtime, notarization.
- App updates through Sparkle 2 with EdDSA signatures.
- Hardened-runtime entitlement for Apple Events, with a usage description.
- Secrets in the Keychain only.
- Builds used for development must be properly signed: recent macOS drops synthetic key events from ad-hoc-signed binaries *(unverified; confirm in M0)*.

### 11.5 Compatibility

- macOS 14 or later (PopClip requires 13.5). A universal binary.
- It relies on the standard ⌘X, ⌘C and ⌘V bindings; remapping them system-wide is unsupported.

**App matrix:**

| Tier | Expectation | Apps |
|---|---|---|
| **A** | Auto-appear works | Safari, Chrome, Arc, Edge, Brave, Firefox, Mail, Notes, Pages, TextEdit, Preview, Xcode, VS Code, Cursor, Zed, Sublime Text, BBEdit, Slack, Discord, Notion, Obsidian, Messages, WhatsApp, Telegram, Word, Excel, PowerPoint, Outlook, Terminal, iTerm2, Ghostty, Bear, Things, Craft, Linear, the ChatGPT and Claude apps |
| **B** | Keyboard shortcut only | JetBrains IDEs; Word if the stray-copy issue cannot be solved |
| **C** | Documented as unsupported (PopClip cannot support these either) | Adobe apps, Apple Books, Kindle, Pixelmator, QuarkXPress, Alacritty, vim, emacs, virtual machines and remote desktops, Final Draft, Unity |

**Browser capabilities** tracked per browser: basic selection, page URL and title (needed for website rules and Copy with Source), address-bar activation, tab control (background tabs, adjacent tabs), and "open in". Chromium-family browsers and Safari support page info; the Firefox family currently does not. Unavailable metadata is an explicit capability gap: hard website blocks fail closed, and Copy with Source offers clearly labelled quotation-only output.

**Known conflicts to document and detect where possible:** custom cursor utilities, mouse utilities that change click behaviour, launcher features that watch for rapid copies, three-finger drag (adds a system delay), and menu bar managers that hide the icon.

---

## 12. Technical approach (recommendation)

| Component | Approach |
|---|---|
| Language and UI | Swift 6. AppKit for the passive bar (`NSPanel` with `.nonactivatingPanel`); explicitly opened palette/prompt/result surfaces support deliberate keyboard focus and BAR-1 restoration. SwiftUI for Settings. Menu bar agent (`LSUIElement`). |
| Event monitoring | A `CGEventTap` for mouse down, drag, up, scroll and key down. Prefer a tap type covered by the Accessibility grant so users see one permission prompt, not two. |
| Gesture recogniser | A state machine for drag-select, multi-click, Shift-click, long press and ⌘-suppression. |
| Selection reader | ACT-9 strategy chain, privacy gating and per-app policies, with invalidatable attempt IDs, one shared deadline and serialized ownership-aware pasteboard transactions (ACT-10/16). |
| Context and content analysis | Accessibility for editability and formatting; `NSDataDetector` plus custom detectors for URLs, emails and paths. |
| Action resolver | Applies §8.5, global/per-app visibility and local grants; runs population within the remaining shared budget, not a separate timer. |
| Extension host | XPC helper embedding JavaScriptCore with capability-checked host APIs. Shell, AppleScript, Shortcuts and Services use `Process`, OSAKit, `shortcuts`/Shortcuts Events and `NSPerformService` through a cancellable host execution boundary; none may block the UI thread. Bind host requests/results to invocation IDs and verify destinations before synthetic input or text mutation. Disclose delegated effects outside this boundary. |
| Storage | Extensions on disk; settings in user defaults; stable layout/option IDs and tombstones in a CloudKit-backed store (Developer ID provisioning required). Conflicts follow SYN-2; trust grants stay local. Source builds disable CloudKit, but offline configuration export/import works in all builds. |
| Contributor builds | macOS ties the Accessibility grant to the code signature, so the build guide has contributors sign with a stable local certificate. Otherwise every rebuild loses the grant. |
| Updates | Sparkle 2 for the app. Extension updates use validated staged packages, atomic activation and recoverable prior versions (EXM-12/13). Safe mode bypasses third-party loading before initialization. |
| Directory | A GitHub App webhook feeding a validator, a review queue, a signing service, object storage behind a CDN, a small JSON API and a static website. |

**Spikes required in M0:**

1. Which window level and collection behaviour reliably show the panel above fullscreen apps on macOS 14, 15 and 26. Sources disagree.
2. Event-tap type versus permission prompts.
3. Selection-read success rate and latency per strategy across Tier A apps.
4. Accessibility-tree enabling for Chromium and Electron apps without window-animation side effects.
5. JavaScriptCore in a sandboxed XPC helper: startup time, network gating, and interpreter-only performance without the JIT entitlement.
6. Clipboard transaction ownership and destination verification under delayed copy, concurrent user copy, source edits and app switches. Record which app/strategy combinations cannot safely support fallback or replacement; disable those paths rather than weakening the guarantees.

---

## 13. Open-source model and distribution

PappuClip is fully open source and free. There are no paid tiers, trials or licence keys.

- **Distribution:** official builds are signed with a Developer ID, notarized, and published as GitHub Releases with Sparkle updates. Add a Homebrew cask. The Mac App Store is not possible: the sandbox blocks the Accessibility and event-posting APIs this kind of app depends on, which is why PopClip left it.
- **Source licence (recommendation, open for decision):**
  - **GPL-3.0 for the app.** It allows reuse of code from the GPL-3.0 selection-detection projects (Easydict, Selected), which cover the hardest part of the product, and it keeps forks open. The bundled JavaScript libraries and Sparkle are permissively licensed and compatible with it.
  - **MIT for everything extension authors touch:** the TypeScript types, the template repo and example extensions. Authors then carry no obligations from us.
  - The alternative is MIT for the app as well. That is simpler and friendlier to reuse, but rules out borrowing GPL code and allows closed-source forks.
  - Either way, do not copy from AGPL projects.
- **Extensions are separate works.** They run against a documented API and may use any licence. The project FAQ says so explicitly. The directory requires a licence file (PUB-4) but does not dictate which one.
- **Directory backend and website:** open source in the same organisation, so the community can audit review and signing. The signing key itself stays private.
- **Running costs** fall on the maintainer: the Apple Developer Program membership (needed for Developer ID signing, notarization and CloudKit), a domain, and directory hosting, which a static site on a free CDN tier can cover at first.
- **Sustainability:** GitHub Sponsors or Open Collective, linked from the App tab and the website. Donations never unlock features.
- **Governance:** a contribution guide, a code of conduct, a public roadmap, and a written policy on who can approve and sign directory extensions.

---

## 14. Legal and IP

This section is not legal advice. Review with counsel before launch.

| Topic | Position |
|---|---|
| **Name** | The name is PappuClip. The risk is moderate, not zero. The test is likelihood of confusion, and courts weigh how alike the names are together with how alike the products are. "Pappu" is a distinct word that sounds and reads differently from "Pop", and "Clip" is a common, descriptive element. Against that, both names share the P…Clip shape, the products are in the identical category, and PappuClip openly models itself on PopClip. Registration is not decisive either way: unregistered marks are protected in the US and in the UK, where Pilotmoon is based. Being free and open source does not exempt a project from trademark law. The realistic worst case is a request to rename. |
| **Name mitigations** | Make the visual identity unmistakably different: icon, colours, bar styling, website. Never use "PopClip" in the name, domain, icon or bundle identifier. Put a "not affiliated with Pilotmoon Software" line on the website, the README and the About panel. Keep the app name in one constant and keep file extensions and URL schemes easy to change, so a rename would be cheap. Before the public launch, spend ten minutes on the USPTO, UKIPO and EUIPO search pages and record what they show. |
| **Compatibility claims** | Descriptive statements such as "runs PopClip extensions" are the normal way to describe compatibility. State clearly that there is no affiliation with Pilotmoon Software. |
| **The extension format** | It is publicly documented. The research found no statement from the developer either permitting or prohibiting third-party implementations, and at least two other projects already load PopClip extensions. |
| **First-party extensions** | MIT-licensed. Redistribution is allowed with the copyright notice kept. Check each extension's readme for exceptions and bundled code. |
| **Third-party extensions** | Each needs its own licence. Several are GPL or unlicensed. Redistribute only with a licence that allows it, or with the author's participation (PUB-2). |
| **Docs and types** | PopClip's docs are CC-BY-SA-4.0 and its type definitions have no licence. Write our docs and types ourselves. |
| **Logos in icons** | Third-party app logos are a trademark matter separate from the MIT licence. Use them only to identify compatible apps and carry a disclaimer. |
| **PopClip's directory** | It has no terms for API consumers. Do not hotlink, scrape or mirror it. |
| **Courtesy** | Consider contacting the PopClip developer before launch. The ecosystem is small and goodwill matters. |
| **Open-source references** | What can be borrowed depends on the licence chosen in §13. With GPL-3.0, code from GPL-3.0 and MIT projects can be reused with attribution. With MIT, only permissively licensed code can. AGPL code is excluded in both cases. |

---

## 15. Roadmap

The durations below are the prior v0.2 estimates for one full-time developer with AI assistance, not commitments for the expanded v0.3 scope. Re-estimate after M0, especially M3–M5; do not assume the new safety and selection-first features fit the old durations. The palette and rich-result experience take precedence over cosmetic parity polish, but all P1 requirements remain 1.0 exit criteria.

| Milestone | Prior baseline duration | Exit criteria |
|---|---|---|
| M0 Spikes | 2 weeks | All six spikes in §12 answered with measurements; unsafe detection/mutation paths identified; stage budgets and milestone estimates revised |
| M1 Core bar | 5 weeks | Auto-appear in 80% of Tier A apps; Cut, Copy, Paste, Search and Open Link; exclusions, app hard blocks and pause; keyboard/VoiceOver access; clipboard-race and action-lifecycle scenarios pass |
| M2 Extension runtime 1 | 5 weeks | Snippets/packages and all six non-JS types work; options; capability summaries and consent on every install route; identity collisions do not silently replace code |
| M3 JavaScript runtime | 6 weeks | API conformance; module/dynamic/auth extensions; helper isolation; shared budgets; capability-checked host calls; native result/prompt APIs with cancellation and destination checks |
| M4 Selection-first and parity UX | 7 weeks | P1 app UX in §7: palette, rich results, per-app sets, prompts, no-code actions, configuration portability, website rules and sync conflict/local-approval scenarios; remaining parity controls and accessibility verified |
| M5 Ecosystem | 8 weeks | End-to-end publish/sign/install/update; atomic failure recovery, rollback, safe mode and capability-increase consent; §9.5 workflow/quality gates met, including Copy with Source; 150 packages is a stretch target |
| M6 Beta to 1.0 | 6 weeks | All P0/P1 requirements and §3.3 metrics met; frozen corpus results published; safety exceptions and unsupported paths documented; contributor docs and signed release pipeline live |

The repository is public from M1, so contributors can help with the app matrix and the catalogue port early.

**Testing strategy:**

- **Compatibility corpus:** freeze and classify as in §3.3; load every eligible unmodified package in CI. Functional results use the same denominator; missing dependencies/credentials and untested packages remain non-passes. Verify the separately ported launch packages against real dependencies.
- **API conformance:** cover observable behaviour and safety exceptions across documented APIs, config keys and enums, including cancellation, effective capabilities and native result/prompt contracts.
- **App/gesture matrix:** automated UI scenarios where feasible, plus a manual Tier A checklist per release. Include non-trigger interactions for false-positive rates, keyboard/VoiceOver navigation, focus return, multi-display operation and unavailable browser metadata.
- **Clipboard and lifecycle:** exercise ACT-10/16 and RUN-5 races, including delayed synthetic copy, intervening user copy, cancellation, source edits and app switches. No wrong-destination mutation or overwriting newer clipboard data is acceptable.
- **Trust and recovery:** signed and unsigned capability consent; URL/Shortcut/Service effects; collisions and approved identity migrations; update interruptions; denied capability increases; rollback/revocation; safe-mode launch with a crashing extension.
- **Sync and portability:** offline/concurrent edits, deletion tombstones, conflict recovery, local approval before synced code loads, secret isolation and offline export/import round trips.
- **Launch improvements:** searchable palette respects context and per-app visibility; rich results preserve multiline text and disable unsafe replacement; prompt cancellation stops the invocation; action templates escape input; Copy with Source preserves attribution or explicitly offers quotation-only output.

---

## 16. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Selection detection is unreliable in important apps | High | High | M0 spikes; per-app policies updatable without a release (ACT-11); the inspector (DIA-2); honest Tier B and C lists |
| A macOS release breaks Accessibility, event taps or synthetic events | Medium | High | Test on betas early; keep the strategy chain pluggable |
| A request to rename because of the similarity to "PopClip" | Low to medium | Medium | The mitigations in §14: distinct identity, non-affiliation notice, a name that is cheap to change |
| Maintainer burnout or running costs with no revenue | Medium | High | Sponsorship links; a directory that costs almost nothing to host; shared review duties as trusted contributors emerge |
| PopClip's format evolves and we fall behind | High | Medium | Track its developer changelog; API-level gating (§8.1); conformance suite |
| A malicious extension reaches users | Low | High | Review plus effective capability consent independent of signature; identity-bound grants/secrets; revocation and safe mode |
| The catalogue port takes longer than expected (licences, logos, dead services) | Medium | Medium | Launch on verified workflow coverage (§9.5), not a package count; 150 remains a stretch target |
| Manual review becomes a bottleneck | Medium | Medium | Strong automated checks; prioritise narrow effective capabilities, not JavaScript/action-type labels alone |
| A solo developer is a single point of failure for the directory | Medium | Medium | Static, CDN-served directory; installed extensions never depend on the server |
| Users see little reason to switch from PopClip | Medium | Medium | Ship palette, rich results, per-app sets and prompts at 1.0 alongside compatibility and explicit safety guarantees |
| More launch features make the old schedule unrealistic | High | Medium | Re-estimate after M0; implement selection-first UX before cosmetic polish; keep streaming, action chains and the shared AI layer post-launch |
| Clipboard ownership or destination verification is unavailable in an app | High | High | Skip unsafe fallback/mutation, explain the limitation, retain results for explicit copy; never weaken data-safety guarantees to satisfy app coverage |

---

## 17. Open questions

**Decisions for the product owner:**

1. *(Decided)* The name is PappuClip.
2. *(Decided)* Fully open source and free. Still open: the source licence, GPL-3.0 (recommended) or MIT (§13).
3. Whether a courtesy contact with the PopClip developer happens before or after a public beta.
4. Minimum macOS version: 14 (recommended) or match PopClip at 13.5.
5. *(Decided)* DIF-1–4 ship in 1.0 with bounded scope: completed rich results, searchable palette/hybrid activation, one-field prompts and stable-order per-app visibility. Streaming, configurable activation modifiers and per-app custom ordering remain P2.
6. Forum platform: GitHub Discussions to start, or Discourse.
7. *(Decided)* Launch catalogue acceptance is verified workflow coverage and per-package functional quality (§9.5); 150 packages is a stretch target, not a minimum.

**Facts the research could not verify:**

- PopClip's behaviour with multiple displays, fullscreen apps and Spaces. BAR-2 is our own specification.
- The number of steps on PopClip's size slider, and whether a separate "Style" appearance setting still exists.
- Whether PopClip shows the unsigned warning for snippets installed from selected text.
- Exact identifier rules (docs and changelog differ; FMT-6 takes the permissive union).
- Whether `POPCLIP_EMAILS` and `POPCLIP_PATHS` are still set in the current build.
- PopClip's signature format and key (undocumented).
- Whether "PopClip" is a registered trademark. A web search on 2026-09-20 produced no register entry either way; the official search pages need a manual check.
- Install and popularity figures for any extension.
- Current prices (the buy page loads them dynamically).
- Details of the open-source clones beyond their READMEs.

---

## Appendix A — Legacy key map

Applied after normalisation (FMT-5).

| Accepted | Canonical |
|---|---|
| `apple script`, `apple script file`, `apple script call` | `applescript`, `applescript file`, `applescript call` |
| `java script`, `java script file`, `js` | `javascript`, `javascript file`, `javascript` |
| `blocked apps` | `excluded apps` |
| `flip horizontal`, `flip vertical` | `flip x`, `flip y` |
| `id` | `identifier` |
| `image file` | `icon` |
| `lang` | `language` |
| `mac os version`, `required os version` | `macos version` |
| `pop clip version`, `required software version` | `popclip version` |
| `params` | `parameters` |
| `pass html` | `capture html` |
| `preserve image color` | `preserve color` |
| `regular expression` | `regex` |
| `script interpreter` | `interpreter` |

Removed in PopClip and ignored here: `alternateUrl`, `Long Running`, the `html` requirement, `util.buildQueryUrl()`.

## Appendix B — PopClip build numbers

Used to interpret `popclipVersion`.

| Version | Build | Version | Build |
|---|---|---|---|
| 2021.9 | 3510 | 2024.5 | 4578 |
| 2021.11 | 3785 | 2024.12 | 4688 |
| 2022.5 | 3895 | 2025.9 | 5118 |
| 2022.12 | 4069 | 2025.9.2 | 5155 |
| 2023.7 | 4151 | 2026.7 | 5992 |
| 2023.9 | 4225 | 2026.8 | 6159 |
| 2024.3 | 4508 | 2026.8.1 | 6221 |

## Appendix C — Launch catalogue by category

Examples are from PopClip's public directory except the native Copy with Source addition. **Tier 1** categories guide porting order; the required workflows in §9.5, not every example here, define launch coverage. At least one notes and one task integration are required even though broader coverage of those categories is Tier 2.

| Category | Tier | Examples |
|---|---|---|
| Text editing | 1 | Paste and Match Style, Formatting, Select All, Paste and Enter, Delete, Highlight |
| Text case | 1 | Uppercase, Lowercase, Capitalize Words, Title Case, Sentence Case |
| Text transformation | 1 | Brackets, Quotes, Remove Spaces, Join Lines, Slugify, HardWrap, Straighten Quotes, ROT13 |
| Lists | 1 | Sort, Reverse, Shuffle, Comma List |
| Markdown | 1 | Copy as Markdown, Markdown to RTF, Markdown to HTML, Code, Blockquote |
| Research and attribution | 1 | Copy with Source (native; CAT-1) |
| Statistics and output | 1 | Word Count, Character Count, Line Count, Say, Large Type |
| Clipboard | 1 | Append to Clipboard, Swap with Clipboard |
| Search engines and websites | 1 | Google, DuckDuckGo, Kagi, Wikipedia, YouTube, Amazon, Wolfram Alpha, Google Scholar, Wayback Machine |
| Translation and dictionaries | 1 | Google Translate, DeepL, Instant Translate, Online Dictionary, Online Thesaurus |
| Developer tools | 1 | Format JSON, Coding Cases, Base64, URL Encode, HTML Encode, Unix Time, Terminal, Color Conversion, Comment |
| Calculators and utilities | 1 | Calculate, Convert, Currency Converter, Sum, Timestamp, Password Generator |
| AI | 1 | OpenAI-compatible chat, Ollama, ChatGPT, Claude and Perplexity launchers |
| Notes and knowledge | 2 | Obsidian, Notes, Bear, Craft, Drafts, DEVONthink, Logseq, Notion, Evernote, Stickies |
| To-do | 2 | Reminders, Things, Todoist, TickTick, OmniFocus, TaskPaper |
| Calendar and contacts | 2 | Fantastical, BusyCal, Cardhop |
| Launchers and shelves | 2 | Raycast, Alfred, LaunchBar, Yoink, Dropover |
| Links | 2 | Shorten Link, Bitly, Raindrop.io, Instapaper, Readwise, Open in Browser, Copy Link to Highlight |
| Maps, music, social | 2 | Google Maps, Apple Maps, Spotify, Apple Music, LinkedIn |
| Other native apps | 2 | Email, Messages, Slack, Day One, TextEdit, BBEdit |
| Phone | 3 | Call |

## Appendix D — Sources

- **PopClip site:** home, user guide, changelog, beta notes, download, buy, knowledge base (troubleshooting, browsers, sync, AppleScript, paths), terms and privacy — https://www.popclip.app/
- **Developer docs** and `popclip.d.ts` — https://www.popclip.app/dev/
- **Directory**, category pages, author pages and submission guide — https://www.popclip.app/extensions/
- **Repos:** https://github.com/pilotmoon/PopClip-Extensions (MIT), https://github.com/pilotmoon/PopClip-Localization, https://github.com/pilotmoon/pcx-directory
- **Forum** — https://forum.popclip.app/
- **macOS technical references:** Apple developer documentation and forums, Sparkle documentation, Electron accessibility issues, the Easydict and SelectedTextKit repos
- **Competitor sites:** Alfred, Raycast, SnipDo, LaunchBar, Apple Writing Tools
