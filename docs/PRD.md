# PappuClip — Product Requirements Document

| | |
|---|---|
| **Status** | Draft v0.4 |
| **Date** | 2026-09-20 |
| **Name** | PappuClip (decided; see the trademark note in §14) |
| **Model** | Fully open source and free. No paid tiers, trials or licence keys |
| **Platform** | macOS 15+ (Apple Silicon and Intel) |
| **Reference baseline** | PopClip 2026.8.1 (build 6221, released 2026-09-07), as documented on popclip.app on 2026-09-20 |
| **Companion documents** | [Extension platform specification](spec/extension-platform.md) (§8 and Appendices A–B) and [Safety specification](spec/safety.md) (clipboard, action lifecycle, consent, identity, isolation) |

**How to read this document.** Every requirement has an ID and one priority:

- **P0** — needed for the first usable build (the core bar and the basic extension runtime).
- **P1** — gates 1.0: core parity with explicit safety exceptions, the JavaScript runtime, a verified extension registry, and the selection-first improvements in §10.
- **P1.x** — committed for the 1.x series but does not gate 1.0: iCloud sync, the icon picker, the no-code action creator and cosmetic parity. Full end-user parity (G1) is reached when these ship.
- **P2** — after 1.0 and uncommitted. These are mostly differentiators that PopClip does not have.

An ID with a letter suffix (ACT-17a, ACT-17b) is one part of an original requirement, split so that each part has one priority and one test. A reference to the bare ID (ACT-17) means all of its parts. Dense safety requirements (ACT-10, ACT-16, RUN-1–3, EXM-5, SEC-7, SEC-8) are summarised here and broken into single testable statements in the safety specification.

Facts about PopClip come from its public website, developer docs, type definitions, localization strings, GitHub repos and forum. Anything the research could not confirm is marked *(unverified)* and collected in §18.

**Changes in v0.4.**

- **Scope:** P1 is split into P1 (gates 1.0) and P1.x. iCloud sync, the icon picker, the no-code action creator and cosmetic parity items moved to P1.x (§6, §7).
- **Ecosystem:** the GitHub App, review queue and signing service are replaced by a public registry repo with CI checks, review by pull request and static hosting (§9).
- **Public beta** at the end of M3, with sideloading and Import from PopClip (§6, §15).
- **Safety:** destination verification tiers (RUN-2); two-level consent with batch approval (EXM-5, EXM-15); a default detection policy for unknown apps (ACT-9, ACT-11a); `networkHosts` promoted to P1 (SEC-6); signed remote data (SEC-9); per-extension JavaScript isolation (SEC-1).
- **Latency:** the p95 targets are unchanged. A 700 ms hard cutoff replaces "fast or absent" (§5, §11.1), and the JavaScript helper is kept warm (JS-19).
- **Metrics:** crash-free sessions now has a measurable source (DIA-4); Tier A is split into gating and tracked apps (§11.5); a missed-appearance rate is added.
- **New requirements:** the keyboard tap exists only while a PappuClip surface needs it (ACT-19); PopClip coexistence (ONB-6).
- **Decided:** macOS 15 minimum; GitHub Discussions; the source licence is MIT (§13).
- **Structure:** §8 and Appendices A–B moved to the extension platform specification; safety detail moved to the safety specification; mixed-priority IDs split; the testing strategy has its own section (§16), so Risks is now §17 and Open questions §18.

---

## 1. Summary

PappuClip is a free, fully open-source macOS utility that shows a small floating bar when you select text, or a searchable action palette when you press a shortcut. It combines PopClip extension compatibility with less intrusive interaction and safer text handling. It has three pillars:

1. **The app.** End-user parity with PopClip 2026.8.1, subject to documented safety exceptions: automatic appearance on selection, eight built-in actions, content-aware filtering, an organisable action list, app and website rules, keyboard control and an AppleScript interface. Version 1.0 adds a searchable palette, rich results, per-app action sets and simple extension input prompts. iCloud sync, the icon picker and cosmetic parity follow in 1.x.
2. **The extension platform.** A runtime that loads PopClip's extension format unmodified: `#popclip` snippets, `.popclipext` packages, all seven action types, the JavaScript/TypeScript API, options, authentication and icons. Native additions use separate keys or methods; consent, privacy and destination-safety checks apply to both formats.
3. **The ecosystem.** A public extension registry with no server to operate: authors publish by pull request, CI checks and signs, maintainers review, and the app installs and updates from a static index with one click. It launches with a catalogue ported from PopClip's MIT-licensed extensions.

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
| G1 | End-user feature parity with PopClip 2026.8.1 across the 1.x series, except where documented safety requirements take precedence. 1.0 gates on core parity (P0 and P1); the P1.x items complete it |
| G2 | Extension compatibility: publicly available PopClip extensions load and run unmodified, subject to capability approval and safety checks |
| G3 | A self-sustaining ecosystem: registry, publishing, review, signing, updates and discovery, with no always-on service for the maintainer to run |
| G4 | Reliability at least equal to PopClip in the most-used Mac apps, and better in Chromium and Electron apps |
| G5 | A security model for third-party code that users can understand and trust |
| G6 | Everything is open source and free: the app, the extension SDK and types, the registry and its tooling, and the ported extensions |
| G7 | Less intrusive, selection-first interaction: searchable actions, usable multiline results and predictable per-app action sets |

### 3.2 Non-goals for 1.0

- Paid tiers, trials, licence keys or any feature gating.
- Windows, Linux or iOS versions.
- Mac App Store distribution (technically impossible for this class of app; see §13).
- Becoming a clipboard manager, a general-purpose launcher or a full workflow editor. The action palette operates on the current selection/context only.
- Operating an AI service. AI features use the user's own keys or local models.
- Verifying Pilotmoon's extension signatures. The format is undocumented, so PopClip-signed packages are treated as unsigned.
- Appearing automatically for keyboard-only selections. PopClip does not do this either; the keyboard shortcut covers it.
- iCloud sync, the icon picker, the no-code action creator and cosmetic parity items. These are P1.x. Configuration export/import (§7.15) covers moving between Macs at 1.0.
- An always-on directory backend. The registry is a git repo plus static hosting (§9).

### 3.3 Success metrics

| Metric | Target for 1.0 |
|---|---|
| Time from mouse-up to bar visible (Accessibility path) | ≤ 150 ms at p95 |
| Time from mouse-up to bar visible (clipboard fallback path) | ≤ 350 ms at p95 |
| Hard cutoff for showing the bar | 700 ms from mouse-up, and only while the attempt is still valid (ACT-16). Initial value; M0 may tune it |
| Missed appearances | ≤ 2% of labelled trigger interactions in Tier A gating apps end with no bar by the hard cutoff |
| Frozen compatibility corpus that loads without error | ≥ 98%; denominator and exclusions below |
| Frozen compatibility corpus that passes a functional smoke test | ≥ 95%; blocked and untested cases are not passes |
| Tier A gating apps (§11.5) with working auto-appear | 100%. Tracked apps are measured and published but do not gate the release |
| Crash-free sessions | ≥ 99.8% among opt-in beta diagnostics participants (DIA-4), and no open reproducible crash at release |
| Idle CPU | < 0.5%, with no polling |
| Launch catalogue quality | Every required workflow in §9.5 covered; every launch package reviewed and functionally verified; 150 packages is a stretch target, not a release gate |
| Clipboard integrity | 0 lost newer clipboard writes; 0 temporary fallback contents left behind when restoration is safe, in the race/integrity suite |
| False-positive automatic appearances | ≤ 1% of labelled non-trigger interactions in the release gesture corpus; 0 secure-input or hard privacy-block violations |
| Wrong-destination insertion or post-cancellation insertion | 0 occurrences in the action-lifecycle suite (§7.14) |
| Extension recovery | Failed updates preserve the working version; rollback, revocation and safe-mode scenarios pass |

**Measurement definitions.** Freeze the upstream MIT-repository commit and enumerate all extension packages before beta. Publish a manifest with per-package licence eligibility, action types, dependencies and results. Exclude only packages without redistribution/test permission or for confirmed discontinued services, with reasons recorded before testing. The remaining packages are the common denominator for load and functional percentages; do not shrink it to the tested subset. A functional pass exercises the advertised action and observes its result, with supported app dependencies and dedicated test credentials where needed. Report load-only, dependency/credential-blocked, failed and untested cases separately; none counts as a functional pass. Native ported packages have their own launch-verification record and do not replace the unmodified compatibility corpus.

The gesture corpus records expected trigger/non-trigger outcomes, app and macOS version, strategy and latency. Non-trigger cases include ordinary clicks, drags of non-text content, scrolling, keyboard-only selection and suppression rules. False-positive rate is unexpected appearances divided by non-trigger interactions. Measure latency end-to-end, including content filtering and dynamic actions, on declared Apple Silicon and Intel reference machines with 50 installed extensions. The missed-appearance rate uses the same corpus: trigger interactions with no bar by the hard cutoff, divided by trigger interactions. Collect measurements in the test harness and opt-in beta diagnostics, not selection/app-usage analytics. Crash-free sessions come from DIA-4 only, because nothing else counts sessions; if too few users opt in for the rate to mean anything, report the counts and rely on the no-open-crash criterion.

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
6. An author pushes tag `v1.2.0` to their GitHub repo → the template's Action opens a registry pull request → checks run → a maintainer reviews and merges → the signed package appears in the directory → installed copies update atomically, pausing for approval if capabilities increase.
7. Start a translation in Notes → switch to Terminal before it completes → the result remains available to copy, but nothing is typed into Terminal.
8. Select a quotation in Safari → **Copy with Source** → paste a Markdown quotation with its page title and URL.

---

## 5. Product principles

1. **Invisible until useful.** Automatic appearance never steals focus or blocks typing. Only explicitly opened interactive surfaces may take keyboard focus, and they return it deliberately.
2. **Never lose the user's data.** Temporary clipboard use must not overwrite a newer copy. Restore only while ownership is provable; otherwise preserve the newer state. Clipboard-manager suppression is tested interoperability, not a universal guarantee.
3. **Fast, and never stale.** The p95 targets in §3.3 are the design budget. A selection read that runs past them may still show the bar until the hard cutoff (700 ms), provided the attempt is still valid (ACT-16): a bar that is 200 ms late is better than one that silently fails to appear, which is the reliability complaint in §2.3. After the cutoff, or once the attempt is invalidated, show nothing.
4. **Compatibility first.** When PopClip's documented behaviour and our preference differ, match PopClip unless there is a safety reason not to.
5. **Built-ins are extensions.** The eight built-in actions ship as bundled extensions, so the platform is proven by the app itself.
6. **Safe by default.** Every installation route shows capabilities. Bounded capabilities are approved with the install; unbounded ones (external scripts, script-driven synthetic input, unrestricted network) need a separate default-deny approval regardless of signature (EXM-5). Signing establishes provenance, not harmlessness.

---

## 6. Release phases

| Phase | Contents | Priority covered |
|---|---|---|
| M0 Spikes | Selection detection across the app matrix, panel above fullscreen apps, event tap and permissions, JavaScript sandbox and warm-helper cost in a helper process, quiescence-tier verification | — |
| M1 Core bar | Auto-appear, built-in actions, basic settings, bundled detection policies with the unknown-app default, app exclusions and hard blocks, pause, keyboard access, clipboard ownership and safe action lifecycle | P0 |
| M2 Extension runtime 1 | Snippets and packages, the six non-JavaScript action types, options UI, icons, two-level capability consent and identity-safe install flows | P0 |
| M3 JavaScript runtime and public beta | Full JS/TS API, modules, host-proxied network with `networkHosts`, dynamic actions on a warm helper, external scripts, auth, native rich-result and input-prompt APIs; Import from PopClip with batch approval; PopClip coexistence; a signed, notarized public beta with Sparkle updates and sideloaded extensions | P1 |
| M4 Selection-first UX | Searchable palette, rich results, per-app action sets, input prompts, folders, section separators, instances, website privacy rules, configuration portability, scripting and localization | P1 |
| M5 Registry | Registry repo, CI checks and signing, static index and website, atomic updates and rollback, revocation, safe mode, one-click install, verified launch workflows including Copy with Source | P1 |
| M6 Beta to 1.0 | Compatibility corpus, app matrix hardening, onboarding, licensing, docs | P1 |
| 1.x | iCloud sync, icon picker, no-code action creator, page breaks, action colours, list cut/copy/paste, Auto (Inverse) colour mode | P1.x |
| Post-1.0 | P2 items in §10, including streaming results and bounded action chains | P2 |

The public beta at the end of M3 is the first build aimed at PopClip switchers. Import from PopClip (EXM-11) brings their installed extensions across before any registry exists, so the registry is not on the critical path to a useful release.

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
| ACT-6a | The shortcut opens compact keyboard mode (BAR-9). | P0 |
| ACT-6b | In 1.0 the shortcut opens the searchable palette (BAR-16) by default; users may choose the compact keyboard bar instead. | P1 |
| ACT-7 | Holding ⌘ while selecting suppresses the bar for that selection. | P0 |
| ACT-8 | Keyboard-only selections (Shift+arrows) do not trigger auto-appear. | P0 |
| ACT-9 | The selection is read through a strategy chain, stopping at the first success: (1) Accessibility attributes of the focused element; (2) WebKit text-marker attributes; (3) per-app enabling of the Accessibility tree for Chromium and Electron apps, toggled narrowly to avoid window-animation side effects; (4) AppleScript for browsers that need it; (5) simulated ⌘C with clipboard save and restore. Strategy 5 runs on the automatic path only in apps whose detection policy allows it (ACT-11a). Apps with no policy use strategies 1–4 automatically and all five from the shortcut. | P0 |
| ACT-10 | The simulated-⌘C fallback is a serialized, ownership-tracked clipboard transaction. It snapshots the whole pasteboard first and skips the fallback if the snapshot would be unsafe or would not fit the remaining budget; restores only while the temporary state is provably its own; never overwrites a newer user or app copy; never treats an unrelated copy as the selection; and marks its own writes as transient and concealed. Testable statements: safety spec §S2 (ACT-10a–j). | P0 |
| ACT-11a | Each app has a detection policy shipped as bundled data: strategy order, whether auto-appear is allowed, whether synthetic copy may run on the automatic path, whether the quiescence tier may be used (RUN-2), and known quirks. The default policy for an unlisted app disallows synthetic copy on the automatic path. Apps that copy the whole line when nothing is selected (VS Code, Sublime Text, JetBrains IDEs) are flagged, and synthetic copy never runs automatically there. | P0 |
| ACT-11b | Policies update without an app release, as signed declarative data under SEC-9. | P1 |
| ACT-12 | The bar never appears, and the selection is never read, for secure text fields or while secure input is active. | P0 |
| ACT-13 | Selections of up to 10 million characters are handled without hanging. Expensive analysis is skipped or bounded for very large selections. | P1 |
| ACT-14 | Do not depend on cursor shape alone to decide that text was selected. It may be one signal among several. | P0 |
| ACT-15 | The event tap is health-checked and reinstalled if macOS disables it. | P0 |
| ACT-16 | A newer selection, focus/context change, privacy-state change or the hard cutoff (§11.1) invalidates pending detection work. Late completions cannot show a stale bar, supply stale action input or restore over a newer clipboard write. Delayed synthetic-copy responses and timeout cleanup obey ACT-10. Testable statements: safety spec §S2 (ACT-16a–c). | P0 |
| ACT-17a | **Never read text here** is a hard privacy rule, distinct from appearance exclusions. App rules apply before any selection read and to automatic, hotkey and scripted activation. Secure input always blocks access. Precedence: secure input/hard block/pause, then activation mode, then action filtering (safety spec §S1). | P0 |
| ACT-17b | Website hard blocks use available page metadata before reading text. If website hard blocks are configured and the current browser URL cannot be established, selection access in that browser is blocked with an explanation. | P1 |
| ACT-18 | Menu-bar Pause offers **For one hour**, **Until resumed**, and **Resume**. While paused, do not capture selections or start actions through any activation route; cancel pending reads/actions under RUN-3. Hotkeys explain the paused state without reading text. Persist pause across relaunch, use an absolute expiry for timed pause, and show its state in the menu. | P0 |
| ACT-19 | Key-down events are tapped only while a PappuClip surface needs them: a visible bar (BAR-9 navigation, BAR-10 dismissal), an in-flight invocation that may mutate text (RUN-2g), or an open clipboard transaction (ACT-10), which watches listen-only for the length of its window and consumes no key. At all other times no keyboard tap is installed, so PappuClip never sits in the path of ordinary typing. The global shortcut uses the system hotkey API, not the tap. Modifier state for ACT-7 and BAR-11 comes from mouse-event flags. | P0 |

### 7.2 The bar

| ID | Requirement | Pri |
|---|---|---|
| BAR-1 | The automatically appearing bar is a non-activating floating panel: it never takes focus from the app underneath. An explicitly opened palette, input prompt or interactive result panel may take keyboard focus. On close, restore focus to the originating app/control only if it remains valid and the user has not switched elsewhere; never reactivate it merely because background work finished. | P0 |
| BAR-2 | It appears on the display that contains the selection, above fullscreen apps, in every Space and under Stage Manager. It is clamped to the visible frame of that display. *(PopClip's behaviour here is undocumented; this is our own specification.)* | P0 |
| BAR-3 | Position: a "Position" setting of Above Text or Below Text applies to single-line selections. For multi-line selections the bar appears below the pointer if the user dragged downwards and above the selection if they dragged upwards. When selection bounds are unknown, the pointer location is used. | P0 |
| BAR-4 | An action may ask to be the primary button, centred under the pointer when the bar appears (`wantsPrimaryDisplay`; Copy and Paste use it). | P1 |
| BAR-5a | The bar grows to use available screen width, capped on very wide displays. Overflow goes to further pages through a "More (Page n of m)" button. | P1 |
| BAR-5b | A Page Break separator forces a split. | P1.x |
| BAR-6 | Each action shows as an icon or as text, per action. Hovering shows the action name as a tooltip. | P0 |
| BAR-7 | Folders appear as buttons that open a submenu on hover. An action that has its own behaviour and also a submenu opens the submenu on secondary click. Submenus nest. A submenu can replace the bar content with a back button (as Spelling does). | P1 |
| BAR-8a | Appearance: vibrancy background, a small callout arrow towards the selection, highlight in the system accent colour, and a colour mode that follows the system. | P0 |
| BAR-8b | Light, Dark and Auto colour modes, and a size slider with live preview. | P1 |
| BAR-8c | Auto (Inverse) colour mode. | P1.x |
| BAR-9a | Compact keyboard mode: ← and → move between actions, Return runs the highlighted action, Esc or any other key dismisses. Navigation keys are consumed, not sent to the source app. Tooltips show during navigation. | P0 |
| BAR-9b | ↑ and ↓ enter and leave folders. | P1 |
| BAR-10 | Passive bar dismissal has no timer: outside click, an ordinary key (passed through), pointer departure or scroll dismisses it. BAR-9 navigation keys are exempt. Explicitly opened palettes, prompts and result panels use their own focus/keyboard rules and do not dismiss merely because the pointer leaves or the user scrolls their contents. | P0 |
| BAR-11 | Modifier keys held at click time (⇧ ⌃ ⌥ ⌘) are captured and passed to the action. | P0 |
| BAR-12a | Feedback states: a spinner while an action runs, which cancels under RUN-3 by click or keyboard; "Copied" confirmation; a tick for success; a shaking X for failure. | P0 |
| BAR-12b | Legacy compact result text is truncated to 160 characters and may offer click-to-paste subject to RUN-2. Native rich results use BAR-17 without changing legacy `after` semantics. | P1 |
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
- **Consent:** the bundled built-ins are approved by installing the app. Onboarding states that Search sends the selected text to the chosen search engine when clicked. A duplicated built-in keeps that approval; an edited one becomes user-generated and follows EXM-5.

### 7.5 Settings

**Menu bar item** (P0): "Appear automatically" toggle, Pause/Resume and pause status (ACT-18), "Settings…" (⌘,), "Quit". Snippet files and selected snippet text can be dragged onto the icon to install them (P1). The icon can be hidden; relaunching the app from Finder reopens Settings.

**Settings window** (standalone window, three tabs; ⌘W closes).

| Tab | Contents | Pri |
|---|---|---|
| **General** | "Appear automatically"; Rules → Apps… separating appearance exclusions from **Never read text here**; shortcut recorder; Appearance (Size, Colour, Position); Accessibility-permission banner | P0 |
| **General**, added for 1.0 | Rules → Websites… (ACT-17b); per-app Automatic / Hotkey only / Off choices; the compact-bar or palette choice for the shortcut (ACT-6b) | P1 |
| **Actions** | Action list (§7.6; each ALM requirement carries its own priority) | P0 |
| **Actions**, added for 1.0 | Search (⌘F); "+" menu with New Folder (⌘N) and New Separator (⌥⌘N); per-app action sets; Get Extensions; Tools menu with Manage Extensions… (⌘E), Import from PopClip and Export/Import Configuration | P1 |
| **Actions**, added in 1.x | New Action in the "+" menu (ALM-9); iCloud Sync in the Tools menu (§7.9) | P1.x |
| **App** | Version and links (website, source code, issue tracker, sponsor); Software Update (check now, Off / Notify only / Install automatically, include betas); Start at login; Show in menu bar; Debug Console. There is no licence or trial section | P1 |

**Rules** (P0 for app exclusions/hard blocks; P1 for the remaining controls):

- **Apps:** automatic-appearance mode is either "Exclude these apps" or "Include only these apps", with a picker of recently used apps. P1 adds explicit per-app **Automatic**, **Hotkey only**, and **Off — never read text** choices. Automatic still respects the global automatic-appearance toggle; Off creates a hard block.
- **Websites:** separate appearance-exclusion and hard-block lists. Rule types are Domain (and subdomains), Host, Starts with, and Other (pattern). Invalid entries are flagged. Page metadata is required; unavailable metadata is explained, and hard blocks fail closed as specified in ACT-17.
- Appearance exclusions restrict only automatic appearance; the hotkey can override them. Hard blocks, secure input and pause cannot be overridden by hotkeys or scripting.

### 7.6 Action list management

| ID | Requirement | Pri |
|---|---|---|
| ALM-1 | There is no limit on the number of actions. | P0 |
| ALM-2a | Per-action commands: Enabled (space bar toggles), Rename (double-click), Change Icon / Reset Icon by icon specifier string, Duplicate, Show As (Icon or Text), Delete, and an Extension submenu with Extension Info and View Source. | P1 |
| ALM-2b | Colour (15 named colours), and Change Icon through the icon picker (§7.7). | P1.x |
| ALM-3a | Reordering by drag and drop, including into and out of nested folders. Undo and redo work. | P1 |
| ALM-3b | ⌘X, ⌘C, ⌘V and "Move Item Here" (⌥⌘V) in the list. | P1.x |
| ALM-4a | Folders and Section Break separators. | P1 |
| ALM-4b | Page Break separators (BAR-5b). | P1.x |
| ALM-5 | Multiple instances of one extension, each with its own name, icon and option values. Duplicate creates an instance. | P1 |
| ALM-6 | A gear button opens a per-action settings sheet generated from the extension's options (§8.9). With no options it says so. | P0 |
| ALM-7 | A newly installed action is highlighted in the list. | P2 |
| ALM-8 | **Per-app action sets:** explicitly show or hide installed action instances by app. Inherit the global user-defined order; no usage-based reordering. App rules can hide an action but cannot enable a globally disabled action, grant capabilities or bypass context requirements/privacy blocks. The palette and bar use the same effective set. Per-app overrides stay local with app rules. | P1 |
| ALM-9 | **New Action** creates a native snippet from a search-URL, open-URL or existing macOS Shortcut template. Provide labelled fields, escaped placeholders, a non-executing input/output preview and a capability summary; any test run is explicit. Saving/installing follows normal identity and consent rules. No new scripting language or arbitrary workflow editor. | P1.x |

### 7.7 Icon picker

P1.x. Until it ships, icons are set by specifier string (ALM-2a). Three tabs:

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
| EXM-5 | Every install route (registry, file, selected snippet, import, generated action or sync) presents the extension's origin and effective capabilities in plain language, at two levels. **Listed** capabilities are bounded and nameable: a URL template, a fixed key combination, a named Service or Shortcut, sandboxed JavaScript limited to granted host methods, `dynamic`, and network access limited to declared `networkHosts`. The single install confirmation approves them. **Gated** capabilities are unbounded: Shell Script and AppleScript actions, the `script` entitlement, script-driven synthetic input, network access without `networkHosts`, and unreviewed code whose reachable host methods cannot be bounded. Each needs a separate approval that defaults to "Don't Allow" and says where the code may act outside the sandbox. A signature never moves a capability from gated to listed, and host calls are checked against grants at call time. Updates use §9.4. Levels and testable statements: safety spec §S4 (EXM-5a–h). | P0 |
| EXM-6 | Manage Extensions sheet: a list sortable by name or date; per-extension Extension Info, New Instance, View Source and View Web Page; an Updates menu with "Check for extension updates" and "Update automatically". | P1 |
| EXM-7 | Extension Info shows origin (Built-in, Directory, Snippet, User-generated, Imported from PopClip), version, action types, identifier, instance count, entitlements, and signature status (Verified, Unsigned). | P1 |
| EXM-8 | View Source opens a viewer with Export… and Copy Snippet. | P1 |
| EXM-9 | Deleting all of an extension's actions uninstalls it. Built-in actions can be restored. | P0 |
| EXM-10 | If an extension names an app that is not installed (`app.checkInstalled`), a "Missing App" alert offers a link to the app's website. | P1 |
| EXM-11 | **Import from PopClip:** on first run, and from the Tools menu afterwards, if `~/Library/Application Support/PopClip/Extensions` exists, offer to import those extensions and the app-exclusion list. Imported directory extensions are treated as unsigned, so EXM-5 applies through the batch sheet (EXM-15). Ships with the public beta (M3). | P1 |
| EXM-12 | Installs and updates are atomic: validate package, identity, signature where applicable, compatibility and grants before activation. Validation, download or interruption failures leave the working version and options intact. Retain a recoverable previous version and matching non-secret configuration snapshot; never activate partially installed code. | P1 |
| EXM-13 | Manage Extensions offers rollback to a retained, compatible, non-revoked version and a per-extension **Pause updates** control. Revalidate trust/capabilities before rollback; do not restore revoked code or erase newer secrets. Revocation checks remain active while updates are paused. Explain any option-schema rollback limitation before proceeding. | P1 |
| EXM-14 | A documented launch-time safe-mode option works without loading third-party extensions. It disables their code and background population while retaining settings, so users can inspect, roll back or remove a broken extension. Exiting safe mode is explicit. | P1 |
| EXM-15 | **Batch approval:** when several extensions arrive together (Import from PopClip, configuration import, sync), one review sheet lists them all with their capabilities. Extensions with only listed capabilities are approved together by one confirmation after the list is shown. Each extension with a gated capability has its own switch, off by default. Unapproved extensions stay installed but disabled, and can be approved later from Extension Info. Testable statements: safety spec §S4 (EXM-15a–d). | P1 |

### 7.9 Sync

P1.x. Sync is not part of 1.0; configuration export/import (§7.15) covers moving between Macs until it ships. Stable instance and list-item IDs (SYN-1) are part of the 1.0 storage format, so adding sync needs no migration. iCloud sync covers installed extensions, the action list layout (folders, separators, names, icons) and per-action option values. Secrets sync through iCloud Keychain unless local-only. General/App settings, app/website rules, per-app action sets and capability grants stay local. Sync is on by default for fresh installs; onboarding explains its scope. Status covers no iCloud account, restricted iCloud and Low Power Mode.

| ID | Requirement | Pri |
|---|---|---|
| SYN-1 | Use stable extension-instance and list-item IDs. Merge independent additions and edits without duplicates; never replace a whole list with one device's snapshot. Deletions propagate as tombstones so an offline device cannot resurrect removed items. | P1.x |
| SYN-2 | Merge non-conflicting fields. Concurrent edits to the same field or item order converge deterministically using logical revision and device-ID tie-breaking, not wall-clock time alone; retain the losing non-secret value/order for explicit recovery. Delete wins over a concurrent edit, with the edited non-secret configuration recoverable locally. Surface conflicts and recovery choices instead of silently losing edits. | P1.x |
| SYN-3 | Synced packages undergo normal validation and local capability consent before their code loads, including population functions. Grants never sync. Synced secrets are inaccessible until local trust and capability approval; sync cannot transfer secrets to a different identity or bypass revocation. | P1.x |
| SYN-4 | Test offline edit/reconnect, concurrent reorder, delete-versus-edit, repeated delivery and a new device receiving an unapproved extension. All devices converge; deletion does not resurrect actions, and unapproved code never executes. | P1.x |

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
| ONB-6 | **PopClip coexistence:** detect a running PopClip (bundle identifier `com.pilotmoon.popclip` *(unverified)*) at launch and when it starts later. Explain that both apps will show a bar, and offer to pause PappuClip's automatic appearance or show how to turn PopClip's off. Never quit, modify or script PopClip. While PopClip is running, PappuClip does not use synthetic copy on the automatic path, so the two clipboard fallbacks cannot race. | P1 |

### 7.12 Localization

P1: all strings externalised; English ships at 1.0; extension names, titles, labels and descriptions accept per-language dictionaries (§8.3). P2: community translations. PopClip ships 19 languages.

### 7.13 Diagnostics

| ID | Requirement | Pri |
|---|---|---|
| DIA-1 | A Debug Console window shows extension `print()` output, load errors and action results. | P1 |
| DIA-2 | A "Why didn't it appear?" inspector shows, for the last selection attempt: the app and its policy, the gesture recognised, each detection strategy tried with its result and timing, and which rule suppressed the bar. | P1 |
| DIA-3 | Opt-in crash reports. No selected text, clipboard content or extension option values are ever included. | P1 |
| DIA-4 | Opt-in beta diagnostics, off by default and offered only in beta builds: a daily anonymous count of PappuClip sessions and crashes with the app and macOS version, plus aggregate latency histograms. No persistent identifier, selected text, clipboard content, app names or option values. This is the only source for the crash-free sessions metric (§3.3). | P1 |

### 7.14 Action lifecycle and safe text mutation

These rules apply to built-ins, legacy actions, native actions and host API calls. They govern PappuClip-controlled effects; arbitrary scripts, Services and Shortcuts can perform external effects outside these guarantees, which capability consent must disclose.

| ID | Requirement | Pri |
|---|---|---|
| RUN-1 | At invocation, capture an immutable input snapshot plus originating app/process, window, focused control and selection context. Track changes separately; never silently retarget an in-flight action to the current app. A focus transfer into an explicitly opened PappuClip surface is tracked as such, not mistaken for a new destination. Testable statements: safety spec §S3 (RUN-1a–c). | P0 |
| RUN-2 | Before any host-controlled cut, insertion, replacement or synthetic input, verify the destination at one of three tiers. **Accessibility-verified:** same element, still editable, same selected range and text. **Quiescence-verified:** same frontmost process and window, no user input events since the snapshot, within a short time window; for apps where the selection was read without Accessibility. **Unverifiable:** mutation is blocked and the result is presented for explicit copy, never auto-copied over a newer clipboard value. Explicit Replace/Insert controls re-verify at click time and are disabled with an explanation when that fails. Recheck privacy rules at execution time. Tiers and testable statements: safety spec §S3 (RUN-2a–h). | P0 |
| RUN-3 | Cancellation immediately invalidates the invocation, rejects later host-effect requests and discards late results instead of pasting, copying or showing success. Owned work is stopped where possible, and the UI says when an external action may already have completed. External effects are never promised to roll back. Pause and revocation invalidate affected invocations in the same way. Testable statements: safety spec §S3 (RUN-3a–f). | P0 |
| RUN-4 | Text replacement participates in the target app's native Undo where supported, preferably as one edit. Document unsupported targets; do not implement an unsafe global Undo by replaying stale text. | P0 |
| RUN-5 | Regression scenarios cover slow translation in Notes followed by switching to Terminal, editing the source while a result is pending, changing selection, closing the source window, entering secure input, cancellation immediately before completion, a new selection racing an older detection, and a quiescence-verified paste with and without an intervening input event. Assert no wrong-destination mutation, no late success after cancellation, and no stale bar. | P0 |

### 7.15 Configuration portability

| ID | Requirement | Pri |
|---|---|---|
| CFG-1 | Export a versioned, portable configuration containing action instances/layout, non-secret option values, settings, app/website rules, per-app sets and extension identities/versions. Include local snippet/package content for backup; do not redistribute it through the directory without licence review. Exclude Keychain secrets, auth tokens, password fields and capability grants; this format has no secret-export mode in 1.0. Warn that ordinary text options or embedded scripts may themselves contain user-entered sensitive data. | P1 |
| CFG-2 | Import previews changes, validates the whole archive before applying them and offers merge or explicitly confirmed replacement with a recoverable non-secret snapshot. Preserve active hard privacy blocks unless their removal is separately confirmed. Packages follow normal validation, collision and local approval rules (EXM-15) before executing. Unsupported versions fail without changing the current configuration; missing secrets require reauthentication. | P1 |
| CFG-3 | Export/import works offline in official and source-built apps, with no iCloud or network dependency. A round trip preserves layout, rules and non-secret options; it never restores grants or exposes a prior identity's secrets. | P1 |

---

## 8. Extension platform requirements

The full specification — formats, config schema, the seven action types, the matching pipeline, script variables, the JavaScript runtime, options, authentication, icons, signing and developer tooling — is in the [extension platform specification](spec/extension-platform.md). Its sections keep the numbers §8.1–§8.14, so references such as §8.5 in this document resolve there. The security model (formerly §8.12) is in the [safety specification](spec/safety.md).

What this PRD commits to:

- **The native format is PopClip's documented format** plus clearly marked native-only additions. The runtime emulates PopClip API level **6221** (§8.1).
- **Legacy behaviour is preserved except for explicit safety exceptions:** capability consent, identity-bound secrets, privacy blocks, clipboard ownership, destination validation and execution budgets. The compatibility guide and conformance results document each one.
- **Native additions in 1.0:** `pappuAfter: rich-result`, `pappuclip.showResult` (JS-17), `pappuclip.promptText` (JS-18), `networkHosts` (SEC-6), `replaces`, and the warm helper for dynamic actions (JS-19).

| IDs | Subject | Where |
|---|---|---|
| FMT-1–7 | Snippets, packages, key normalisation, identifiers | Extension spec §8.2 |
| — | Config schema, action types, matching pipeline, `before`/`after`, script variables | Extension spec §8.3–8.7 |
| JS-1–19 | JavaScript runtime | Extension spec §8.8 |
| — | Options, authentication, icons | Extension spec §8.9–8.11 |
| SEC-1–9 | Consent, identity, isolation, remote data | Safety spec §S4–S6 |
| — | Signing | Extension spec §8.13 |
| DEV-1–6 | Developer tooling | Extension spec §8.14 |

---

## 9. Ecosystem requirements

### 9.1 Directory website

The website is static and regenerated from the registry (§9.3) on every merge. Search and sorting run in the browser over the static index.

| ID | Requirement | Pri |
|---|---|---|
| DIR-1 | A public site listing every published extension, with curated categories (start from PopClip's 31, Appendix C), search across name, keywords, associated apps **and description**, and sorting by newest, recently updated and most installed. | P1 |
| DIR-2 | A listing page shows: icon, name, author, description, demo video or GIF, rendered readme, version and dates, identifier, licence, minimum app version, action types and capabilities in plain language, source link pinned to the exact commit, associated apps, previous versions, and an Install button. | P1 |
| DIR-3 | Install opens `pappuclip://install?…`. The app confirms with the user, downloads, verifies the signature and installs. A plain download link is the fallback. | P1 |
| DIR-4 | Author pages, a "Newly Added" section and a featured slot. | P1 |
| DIR-5 | Anonymous install counts, taken from the static host's per-file download statistics where it provides them. No user identifiers and no counting service of our own. | P1 |
| DIR-6 | Ratings and reviews. | P2 |

### 9.2 In-app discovery

| ID | Requirement | Pri |
|---|---|---|
| STORE-1 | "Get Extensions" opens the directory website. | P1 |
| STORE-2 | An in-app browser for the directory with search, categories and one-click install. | P2 |

### 9.3 Publishing pipeline

There is no GitHub App, webhook service or review queue to operate. The registry is a git repo; GitHub pull requests are the queue and CI is the pipeline.

| ID | Requirement | Pri |
|---|---|---|
| PUB-1 | The registry is a public git repo. Each extension has one entry file naming the author's public source repo, a version tag and the pinned commit. Authors publish or update by pull request to the registry. The template repo includes an optional GitHub Action that opens that pull request when the author pushes a version tag. | P1 |
| PUB-2 | Package selection comes from `pappuclip-directory.yaml` in the source repo (`include` globs, optional `exclude` and `versionPrefix`). If it is absent, `popclip-directory.yaml` is read instead, so an author already publishing to PopClip dual-publishes with one registry pull request and no changes to their repo. CI verifies that the pull-request author has write access to the source repo; that is the author's explicit consent. | P1 |
| PUB-3 | Versions are git tags of one to four dot-separated integers, strictly increasing. In a monorepo only changed packages take the new version. | P1 |
| PUB-4 | Automated checks run in CI on the pull request: required fields (`name`, `identifier`, `description`, a minimum version key), identifier never changes, limits of 100 files, 1 MiB per file and 2 MiB in total, no minified or binary content, a licence file present, `shellScriptRationale` of at least 20 characters for shell actions, and `networkHosts` present for packages in our namespace that use `network`. Results appear as checks on the pull request. | P1 |
| PUB-5 | Human review is the pull-request review: not malicious, does what it says, uses sandboxed JavaScript where that can do the job, and the recorded effective capabilities (including any `networkHosts` the entry supplies for a package that lacks them) match the code. Merging is approval. There is a published review policy, a target turnaround and a written list of who may merge. | P1 |
| PUB-6 | On merge, the release workflow builds the package from the pinned commit, strips files starting with `_` or `.` and the readme and demo media, signs it (§8.13), uploads it to static hosting and regenerates the index and the website. | P1 |
| PUB-7 | Authors unpublish by pull request. Maintainers can unlist, and can revoke in an emergency (SEC-5). | P1 |

### 9.4 Updates

P1. Directory extensions update automatically (user-controllable), using atomic activation and recoverable snapshots (EXM-12). The app downloads the static index and compares versions locally, so the check reveals nothing about which extensions are installed. Show a capability delta and require approval before activating any update that expands effective access: new entitlements/action types, newly controlled apps, wider declared destinations or broader host/delegated automation access (SEC-7). Do not infer safety from an unchanged entitlement array or signature. Until approved, retain the working version unless revoked. Trust changes follow SEC-8. Failed updates leave the current version usable; rollback, pause and revocation follow EXM-13 and SEC-5.

### 9.5 Launch catalogue

- **Source:** the `source/` folder of `pilotmoon/PopClip-Extensions` (about 220 maintained packages), licensed MIT, "Copyright (c) 2012 Nicholas Moore and contributors", "unless stated otherwise in the extension readme files".
- **Process per extension:** check its licence and bundled third-party code; preserve copyright and author credit; assign a new identifier under our namespace with a reviewed `replaces` mapping; declare `networkHosts` for every port that uses `network`; offer approved non-secret option migration to switchers. Grants never migrate; secrets follow SEC-8 or require reauthentication. Review third-party logos and run a functional smoke test on the actual distributed package.
- **Skip** extensions for dead services (for example Pocket, Omnivore, Skype).
- **Do not** hotlink, scrape or mirror PopClip's directory downloads. Extensions outside the MIT repo need their own licence check; some have none and cannot be redistributed.
- **Release gate:** cover every required workflow below with reviewed, signed, functionally verified packages. Record tested package version, input/observable outcome, supported dependencies and test date. No launch package is counted as verified on a load-only check, missing credentials or a simulated external-service response.
- **Required workflows:** case conversion and whitespace cleanup; list sorting; Markdown/rich-text conversion; word/character counts; append/swap clipboard; custom web search; translation; JSON formatting and encoding; calculation/unit conversion; one local-model AI action; capture to a notes app; capture to a task app; and Copy with Source. Pick maintained packages by Appendix C priority; these workflows, not every example in the appendix, define the minimum catalogue.
- **Stretch target:** 150 packages. A smaller catalogue that satisfies the workflow and quality gates is sufficient for 1.0; catalogue size must not delay a safe, useful release.

| ID | Requirement | Pri |
|---|---|---|
| CAT-1 | **Copy with Source** ships as a catalogue extension, not a ninth built-in. It copies the selected quotation with available page title/URL as plain text or Markdown, preserving text and escaping Markdown correctly. When metadata is unavailable, clearly offer quotation-only copy without inventing attribution or silently claiming a complete citation. It uses metadata already available through the normal privacy-checked context and makes no background network request. | P1 |

### 9.6 Registry and static index

P1. There is no backend service. The release workflow (PUB-6) publishes static files behind a CDN: a full index (identifier, version, capabilities, dates), per-extension detail, versioned package files and the signed revocation list. The website, its search and the app's update checks all read these files, and the app works normally when they are unreachable. The index format is documented and public, a small differentiator since PopClip has no list endpoint. Anyone can mirror or fork the registry.

### 9.7 Community

P1: a discussion forum on GitHub Discussions with categories for help, extension sharing and requests; a contribution guide; snippet sharing that works by select-and-install. P2: a showcase of community snippets inside the directory.

---

## 10. Beyond parity

DIF-1a, DIF-2a, DIF-3 and DIF-4a are part of 1.0. Streaming, richer activation controls and the other items remain post-launch; the action palette is selection-first, not a general launcher.

| ID | Differentiator | Scope and priority |
|---|---|---|
| DIF-1a | **Rich result panel** | P1: multiline text/Markdown with Copy, Replace Selection and Insert (BAR-17, JS-17, `pappuAfter`) |
| DIF-1b | **Streaming results** in the rich result panel | P2: retains the same cancellation and destination-safety rules |
| DIF-2a | **Hybrid activation** | P1: searchable hotkey palette plus per-app Automatic, Hotkey only and Off modes (ACT-6/17, BAR-16). The existing ⌘ suppression (ACT-7) is unchanged |
| DIF-2b | **Configurable activation modifiers** | P2: require or suppress the bar with a chosen modifier |
| DIF-3 | **Input prompt API** | P1: one labelled text field with Submit/Cancel during explicit action execution (JS-18), not arbitrary extension-provided UI |
| DIF-4a | **Per-app action sets** | P1: explicit show/hide overrides with stable global ordering (ALM-8) |
| DIF-4b | **Per-app custom ordering** | P2 |
| DIF-5 | **In-place extension editor** with live reload for snippets | P2. The limited no-code action creator is a separate requirement (ALM-9) |
| DIF-6 | **AI provider layer:** one configuration for OpenAI-compatible, Anthropic and local (Ollama, Apple on-device) models, with the user's keys | P2; 1.0 extensions configure their own providers |
| DIF-7 | **Browser companion extension** for reliable selection and page metadata | P2 |
| DIF-8 | **OCR fallback** for text that cannot be selected | P2 |
| DIF-9 | **Team features:** managed extension sets and configuration profiles | P2 |
| DIF-10 | **Bounded action chains** | P2: explicitly ordered transformations such as trim → format → copy. Show combined capabilities before approval, pass each result to the next step, stop on failure/cancellation and never automatically retry a side-effecting step. Apply normal privacy/destination checks; no branching workflow editor or promise to undo completed external effects |

---

## 11. Non-functional requirements

### 11.1 Performance

- End-to-end latency targets remain ≤ 150 ms p95 on Accessibility and ≤ 350 ms p95 on clipboard fallback (§3.3). Initial shared budgets below sum to those limits; M0 measurements may redistribute stages but may not increase the total without revising the release target. A fallback attempt inherits elapsed time from earlier strategies rather than starting a new timer. The budgets are targets, not the point at which the bar is abandoned: a selection read may run past its stage budget until the hard cutoff of 700 ms from mouse-up, as long as the attempt is still valid (ACT-16).

| Stage | Accessibility path | Clipboard fallback path |
|---|---|---|
| Gesture dispatch, privacy/context checks and selection read | 70 ms | 270 ms, including earlier strategy attempts and safe clipboard cleanup |
| Bounded analysis and static filtering | 20 ms | 20 ms |
| Dynamic population and IPC against a warm helper (JS-19) | 30 ms aggregate, ≤ 15 ms per function | 30 ms aggregate, ≤ 15 ms per function |
| Layout and first visible frame | 30 ms | 30 ms |

- Use one monotonic clock per selection attempt, with the target budget and the hard cutoff both measured from mouse-up. Reserve rendering time; shorten or skip population when upstream work consumes its allocation, and always skip it once the target budget is exceeded, so a late bar is a static bar. Never show a bar after the hard cutoff. Report skipped dynamic actions so a fast but incomplete bar cannot masquerade as successful compatibility. Measure cold and warm paths separately.
- No polling; all detection is event-driven.
- Memory under 80 MB resident for the app with 50 extensions installed. The warm helper (JS-19) has its own budget, set from the M0 spike 5 measurements.
- Ready within one second of launching at login.
- Extension configs are parsed once and cached. JavaScript contexts are created lazily, except for `dynamic` extensions in the warm helper (JS-19).

### 11.2 Reliability

- Extension crashes are isolated from the bar (SEC-1).
- Clipboard fallback restores only while it owns the temporary state (ACT-10). A newer user/app write always wins; ambiguous ownership aborts the read without destructive restoration. Cover delayed copies, timeouts, overlapping reads, rich text, images, unpreservable representations and clipboard-manager interference.
- The event tap is monitored and reinstalled (ACT-15).
- A failed selection read, or one still pending at the hard cutoff, shows nothing; it never shows a stale bar.
- Asynchronous results, cancellation and synthetic input obey RUN-1–5; app switching or source edits never silently retarget an action.
- Atomic install/update, rollback to a non-revoked version, safe mode and sync conflict recovery are release acceptance scenarios, not optional support procedures.

### 11.3 Privacy

- Selected text leaves the Mac only through an explicitly invoked action with approved effective capabilities. Explain URL-based transmission and delegated automation as well as direct network requests.
- No analytics on selections, clipboard content, app usage or option values. Opt-in beta diagnostics (DIA-4) count PappuClip's own sessions and crashes only.
- App update checks carry the app version and macOS version, and no persistent user identifier. Extension update checks download the static index and send no list of installed extensions (§9.4).
- The privacy policy discloses every network endpoint: app updates, the registry index and packages, detection-policy and revocation data (SEC-9), icon lookups, crash reports and opt-in beta diagnostics.
- Keystrokes are observed only while a PappuClip surface needs them (ACT-19).
- Hard privacy blocks, secure input and pause take precedence over all activation routes, including scripts. Unknown browser URLs fail closed when website hard blocks apply (ACT-17).
- Export archives contain no app-managed secrets or grants; disclose potentially sensitive ordinary option/script content (CFG-1). Test/diagnostic exports never include real selection or clipboard content.

### 11.4 Security

- Developer ID signing, hardened runtime, notarization.
- App updates through Sparkle 2 with EdDSA signatures.
- Hardened-runtime entitlement for Apple Events, with a usage description.
- Secrets in the Keychain only.
- Builds used for development must be properly signed: recent macOS drops synthetic key events from ad-hoc-signed binaries *(unverified; confirm in M0)*.

### 11.5 Compatibility

- macOS 15 or later (PopClip requires 13.5). A universal binary.
- It relies on the standard ⌘X, ⌘C and ⌘V bindings; remapping them system-wide is unsupported.

**App matrix:**

| Tier | Expectation | Apps |
|---|---|---|
| **A — gating** | Auto-appear works; 100% is a release gate (§3.3) | Safari, Chrome, Firefox, Mail, Notes, Pages, TextEdit, Preview, Xcode, VS Code, Slack, Notion, Obsidian, Messages, Terminal |
| **A — tracked** | Auto-appear is expected; results are measured and published each release but do not gate it | Arc, Edge, Brave, Cursor, Zed, Sublime Text, BBEdit, Discord, WhatsApp, Telegram, Word (moves to Tier B if the stray-copy issue cannot be solved), Excel, PowerPoint, Outlook, iTerm2, Ghostty, Bear, Things, Craft, Linear, the ChatGPT and Claude apps |
| **B** | Keyboard shortcut only | JetBrains IDEs |
| **C** | Documented as unsupported (PopClip cannot support these either) | Adobe apps, Apple Books, Kindle, Pixelmator, QuarkXPress, Alacritty, vim, emacs, virtual machines and remote desktops, Final Draft, Unity |

The gating list is provisional until M0 spike 3 settles it. After that an app moves between gating and tracked only with a recorded reason, never to make a release pass. A release gate that depends on 37 third-party apps would let any one vendor's update block a release; 15 is enough to cover the main selection-reading strategies.

**Browser capabilities** tracked per browser: basic selection, page URL and title (needed for website rules and Copy with Source), address-bar activation, tab control (background tabs, adjacent tabs), and "open in". Chromium-family browsers and Safari support page info; the Firefox family currently does not. Unavailable metadata is an explicit capability gap: hard website blocks fail closed, and Copy with Source offers clearly labelled quotation-only output.

**Known conflicts to document and detect where possible:** custom cursor utilities, mouse utilities that change click behaviour, launcher features that watch for rapid copies, three-finger drag (adds a system delay), menu bar managers that hide the icon, and a running PopClip (ONB-6).

---

## 12. Technical approach (recommendation)

| Component | Approach |
|---|---|
| Language and UI | Swift 6. AppKit for the passive bar (`NSPanel` with `.nonactivatingPanel`); explicitly opened palette/prompt/result surfaces support deliberate keyboard focus and BAR-1 restoration. SwiftUI for Settings. Menu bar agent (`LSUIElement`). |
| Event monitoring | A `CGEventTap` for mouse down, drag, up and scroll. A key-down tap exists only while a PappuClip surface needs it (ACT-19); the global shortcut uses the system hotkey API. Prefer a tap type covered by the Accessibility grant so users see one permission prompt, not two. |
| Gesture recogniser | A state machine for drag-select, multi-click, Shift-click, long press and ⌘-suppression. |
| Selection reader | ACT-9 strategy chain, privacy gating and per-app policies with a conservative default for unknown apps (ACT-11a), with invalidatable attempt IDs, one clock carrying a target budget and a hard cutoff, and serialized ownership-aware pasteboard transactions (ACT-10/16). |
| Context and content analysis | Accessibility for editability and formatting; `NSDataDetector` plus custom detectors for URLs, emails and paths. |
| Action resolver | Applies §8.5, global/per-app visibility and local grants; runs population within the remaining shared budget, not a separate timer. |
| Extension host | XPC helper embedding JavaScriptCore with capability-checked host APIs: one JavaScript virtual machine per extension, kept warm for `dynamic` extensions (JS-19). The helper has no network or filesystem entitlement; the host performs `XMLHttpRequest` on its behalf and enforces entitlements and `networkHosts` (SEC-1, SEC-6). Shell, AppleScript, Shortcuts and Services use `Process`, OSAKit, `shortcuts`/Shortcuts Events and `NSPerformService` through a cancellable host execution boundary; none may block the UI thread. Bind host requests/results to invocation IDs and verify destinations before synthetic input or text mutation (RUN-2). Disclose delegated effects outside this boundary. |
| Storage | Extensions on disk; settings in user defaults; layout and options in a local store that uses stable IDs and tombstones from 1.0, so the CloudKit-backed sync in 1.x (Developer ID provisioning required) needs no migration. Conflicts follow SYN-2; trust grants stay local. Offline configuration export/import works in all builds. |
| Contributor builds | macOS ties the Accessibility grant to the code signature, so the build guide has contributors sign with a stable local certificate. Otherwise every rebuild loses the grant. |
| Updates | Sparkle 2 for the app. Extension updates use validated staged packages, atomic activation and recoverable prior versions (EXM-12/13). Safe mode bypasses third-party loading before initialization. |
| Directory | A public registry repo; CI for checks, builds and signing; a static index, packages and website behind a CDN. No server to operate. |

**Spikes required in M0:**

1. Which window level and collection behaviour reliably show the panel above fullscreen apps on macOS 15, 26 and the current beta. Sources disagree.
2. Event-tap type versus permission prompts, including installing the key-down tap only while it is needed (ACT-19).
3. Selection-read success rate and latency per strategy across Tier A apps.
4. Accessibility-tree enabling for Chromium and Electron apps without window-animation side effects.
5. JavaScriptCore in a sandboxed XPC helper: startup time, warm-helper memory, pre-warming on mouse-down, host-proxied network, and interpreter-only performance without the JIT entitlement.
6. Clipboard transaction ownership and destination verification under delayed copy, concurrent user copy, source edits and app switches. Validate the quiescence tier (RUN-2): how reliably the event tap and frontmost-window checks detect intervening input, and what time window is safe. Record which app/strategy combinations cannot safely support fallback or replacement; disable those paths rather than weakening the guarantees.

---

## 13. Open-source model and distribution

PappuClip is fully open source and free. There are no paid tiers, trials or licence keys.

- **Distribution:** official builds are signed with a Developer ID, notarized, and published as GitHub Releases with Sparkle updates. Add a Homebrew cask. The Mac App Store is not possible: the sandbox blocks the Accessibility and event-posting APIs this kind of app depends on, which is why PopClip left it.
- **Source licence: MIT** (decided 2026-09-23; the `LICENSE` file at the repository root). The app takes no code from the GPL-3.0 projects, so the second option below applies and the first is kept as the record of what was weighed. Borrowing GPL code is now ruled out.
  - **GPL-3.0 for the app, if the M0 spikes show PappuClip will reuse code from the GPL-3.0 selection-detection projects** (Easydict, Selected), which cover the hardest part of the product. It also keeps forks open. The bundled JavaScript libraries and Sparkle are permissively licensed and compatible with it.
  - **MIT for the app if the spikes show no such reuse.** That is simpler and friendlier to reuse, but rules out borrowing GPL code later and allows closed-source forks. The choice cannot be deferred past M1: without a contributor licence agreement, relicensing after outside contributions arrive needs every contributor's consent.
  - **MIT for everything extension authors touch,** in both cases: the TypeScript types, the template repo and example extensions. Authors then carry no obligations from us.
  - Either way, do not copy from AGPL projects.
- **Extensions are separate works.** They run against a documented API and may use any licence. The project FAQ says so explicitly. The directory requires a licence file (PUB-4) but does not dictate which one.
- **Registry and website:** the registry repo, its CI workflows and the website generator are public, so every review, check result and release is auditable in git history. The signing key itself stays private.
- **Running costs** fall on the maintainer: the Apple Developer Program membership (needed for Developer ID signing, notarization and, in 1.x, CloudKit), a domain, and static hosting, which a free CDN tier can cover at first.
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

The durations below are rough estimates for one full-time developer with AI assistance. They adjust the v0.2 baseline for the v0.4 scope: sync, the icon picker and the no-code creator are out of 1.0, a registry replaces the backend, and M3 gains the public beta. They are not commitments; re-estimate after M0, especially M3–M5. The palette and rich-result experience take precedence over parity polish. 1.0 exits on every P0 and P1 requirement; P1.x items never block it.

| Milestone | Estimate | Exit criteria |
|---|---|---|
| M0 Spikes | 2 weeks | All six spikes in §12 answered with measurements; unsafe detection/mutation paths identified; Tier A gating list, hard cutoff, stage budgets and milestone estimates revised; source licence decided |
| M1 Core bar | 5 weeks | Auto-appear in 80% of Tier A gating apps; Cut, Copy, Paste, Search and Open Link; bundled detection policies with the unknown-app default; exclusions, app hard blocks and pause; keyboard/VoiceOver access; clipboard-race and action-lifecycle scenarios pass |
| M2 Extension runtime 1 | 5 weeks | Snippets/packages and all six non-JS types work; options; two-level consent on every install route; identity collisions do not silently replace code |
| M3 JavaScript runtime and public beta | 7 weeks | API conformance; module/dynamic/auth extensions; per-extension isolation with host-proxied network and `networkHosts`; warm helper within budget; capability-checked host calls; native result/prompt APIs with cancellation and destination checks; Import from PopClip with batch approval; PopClip coexistence; a signed, notarized beta with Sparkle updates released publicly |
| M4 Selection-first UX | 5 weeks | P1 app UX in §7: palette, rich results, per-app sets, prompts, folders, configuration portability and website rules; accessibility verified |
| M5 Registry | 5 weeks | End to end: registry pull request, checks, merge, signed static release, install and update; atomic failure recovery, rollback, revocation, safe mode and capability-increase consent; §9.5 workflow/quality gates met, including Copy with Source; 150 packages is a stretch target |
| M6 Beta to 1.0 | 6 weeks | All P0/P1 requirements and §3.3 metrics met; frozen corpus results published; safety exceptions and unsupported paths documented; contributor docs live |
| 1.x | — | P1.x items: iCloud sync first, then the icon picker, the no-code creator and cosmetic parity |

That is about 35 weeks to 1.0, against 39 in v0.3. The repository is public from M1, so contributors can help with the app matrix and the catalogue port early. The public beta at the end of M3 is the first build aimed at PopClip switchers.

---

## 16. Testing strategy

Each requirement ID, or lettered part, maps to at least one automated test or manual checklist item. The mapping is kept alongside the test suite from M1.

- **Compatibility corpus:** freeze and classify as in §3.3; load every eligible unmodified package in CI. Functional results use the same denominator; missing dependencies/credentials and untested packages remain non-passes. Verify the separately ported launch packages against real dependencies.
- **API conformance:** cover observable behaviour and safety exceptions across documented APIs, config keys and enums, including cancellation, effective capabilities and native result/prompt contracts.
- **App/gesture matrix:** automated UI scenarios where feasible, plus a manual checklist per release for Tier A gating and tracked apps. Include trigger interactions for the missed-appearance rate, non-trigger interactions for false-positive rates, keyboard/VoiceOver navigation, focus return, multi-display operation, unavailable browser metadata, unknown apps under the default policy, and PopClip running alongside.
- **Clipboard and lifecycle:** exercise ACT-10/16 and RUN-5 races, including delayed synthetic copy, intervening user copy, cancellation, source edits and app switches, and both outcomes of the quiescence tier. No wrong-destination mutation or overwriting newer clipboard data is acceptable.
- **Trust and recovery:** listed and gated consent for signed and unsigned code; batch approval; host calls outside the grants; `networkHosts` enforcement; URL/Shortcut/Service effects; collisions and approved identity migrations; update interruptions; denied capability increases; rollback/revocation and refusal of downgrades; signed remote data that tries to loosen a hard block; safe-mode launch with a crashing extension.
- **Registry:** pull-request checks, verification of the author's access to the source repo, the release workflow from merge to static index, and an unreachable index.
- **Portability:** offline export/import round trips and secret isolation. **Sync (1.x):** offline/concurrent edits, deletion tombstones, conflict recovery and local approval before synced code loads.
- **Launch improvements:** searchable palette respects context and per-app visibility; rich results preserve multiline text and disable unsafe replacement; prompt cancellation stops the invocation; Copy with Source preserves attribution or explicitly offers quotation-only output.

---

## 17. Risks

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
| A solo developer is a single point of failure for the directory | Medium | Medium | The registry is a public git repo on static hosting that anyone can mirror; installed extensions never depend on it; a written merge policy lets trusted contributors share review |
| Users see little reason to switch from PopClip | Medium | Medium | Ship palette, rich results, per-app sets and prompts at 1.0 alongside compatibility and explicit safety guarantees; a public beta at M3 with Import from PopClip makes trying it cheap |
| The 1.0 scope is still too large for one developer | Medium | Medium | The P1.x split keeps sync, the icon picker and the no-code creator off the 1.0 path; the registry needs no backend; re-estimate after M0; keep streaming, action chains and the shared AI layer post-launch |
| Clipboard ownership or destination verification is unavailable in an app | High | High | Use the quiescence tier where M0 validates it; otherwise skip unsafe fallback/mutation, explain the limitation and retain results for explicit copy; never weaken data-safety guarantees to satisfy app coverage |
| The quiescence tier pastes into the wrong place | Low | High | M0 spike 6 validates it; a short time window; any input event downgrades to unverifiable (RUN-2g); a per-app policy can disable the tier (ACT-11) |
| The CI-held signing key is compromised | Low | High | Protected environment with required approval; key rotation (§8.13); signed revocation (SEC-5); gated capabilities still need user approval regardless of signature |
| Consent prompts are clicked through without reading | Medium | High | Two-level consent keeps default-deny prompts rare (EXM-5); batch approval never bulk-approves a gated capability (EXM-15) |

---

## 18. Open questions

**Decisions for the product owner:**

1. *(Decided)* The name is PappuClip.
2. *(Decided)* Fully open source and free, under the MIT licence (§13).
3. Whether a courtesy contact with the PopClip developer happens before or after a public beta.
4. *(Decided)* The minimum macOS version is 15. By 1.0, macOS 14 will be three major releases behind, and dropping it removes a third of the fullscreen and event-tap test matrix.
5. *(Decided)* DIF-1a, DIF-2a, DIF-3 and DIF-4a ship in 1.0 with bounded scope: completed rich results, searchable palette/hybrid activation, one-field prompts and stable-order per-app visibility. Streaming, configurable activation modifiers and per-app custom ordering remain P2.
6. *(Decided)* The forum is GitHub Discussions.
7. *(Decided)* Launch catalogue acceptance is verified workflow coverage and per-package functional quality (§9.5); 150 packages is a stretch target, not a minimum.
8. *(Decided)* 1.0 gates on P0 and P1. iCloud sync, the icon picker, the no-code action creator and cosmetic parity are P1.x.
9. *(Decided)* The ecosystem is a registry repo with CI and static hosting, not a backend service. Revisit the CI-held signing key if the registry grows (§8.13).
10. The Tier A gating list (§11.5), the hard cutoff (700 ms) and the quiescence time window (3 s) are initial values. M0 sets them.

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
- PopClip's bundle identifier, assumed to be `com.pilotmoon.popclip` (ONB-6).

---

## Appendix A — Legacy key map

Moved to the [extension platform specification](spec/extension-platform.md#appendix-a--legacy-key-map).

## Appendix B — PopClip build numbers

Moved to the [extension platform specification](spec/extension-platform.md#appendix-b--popclip-build-numbers).

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
