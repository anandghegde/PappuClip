# PappuClip beta notes

For the M3 beta (implementation plan §6, week 7). These notes cover what the beta does, how far it has been checked, and what is known not to work yet. Report anything not listed here.

## Where the beta stands

- **The conformance suite passes, with no expected failures.**
  - Both sections pass under `pappuclip run`: `Tests/conformance/environment/suite.js` and `Tests/conformance/api/suite.js`.
  - The same suites run in `swift test` (DEV-2).
- **Corpus functional pass: 176 of 381 packages (46.2%).**
  - Of the rest, 83 are blocked, 97 load-only, 6 untested and 19 failed.
  - PRD §3.3's target is at least 95%, so this is well short. How to read the number is under "Corpus findings" below.
  - Result file: `Tests/results/corpus-functional/`. Regenerate it with `swift run pappu-dev corpus functional` in `Packages/PappuKit`.
- **The manual checklists have not been run.** None of `docs/checklists/m1-manual.md`, `m2-manual.md`, `m3-manual.md`, `clipboard-managers.md` or `voiceover-bar.md` has been run against a signed build.
  - Every behaviour that only a person at a Mac can confirm is therefore unconfirmed: focus, Undo, VoiceOver, and real apps.
  - Treat the rows as the beta's test plan.

## Known issues

### Panels and results

- **Some apps refuse Replace Selection and Insert from a result panel.** In apps checked only by quiescence (the unverifiable and quiescence tiers, architecture §9.2):
  - Clicking the panel counts as input, so the destination check refuses Replace Selection and Insert and explains why.
  - Copy still works.
  - Examples of such apps are Safari's address bar and Terminal.
  - This is the designed M3 behaviour, not a failure.
- **Insert is a stand-in until M4.**
  - It replaces the verified selection with the original text followed by the result.
  - It does not collapse the selection and insert after it.
  - The result is the same text, but the original's formatting is not kept, and it is one paste rather than an insertion.
  - The panels' look is also M4's (DIF-1a, DIF-3).
- **⇧ Cut and ⇧ Copy do nothing different.** They are not plain-text variants yet (architecture §8.7).

### Import from PopClip and coexistence

- **The PopClip exclusion-list format is unverified.**
  - PappuClip reads `BlockedApps`, an array of bundle IDs, from `com.pilotmoon.popclip.plist`.
  - Nobody has yet checked this against a real PopClip (m3-manual row P1).
  - If the format differs, excluded apps are not imported, and nothing else goes wrong.
- **Launch alerts can overlap.** Several modal alerts can arrive in the same launch, and each runs its own modal session. They are not queued:
  - the PopClip import offer and its result
  - the coexistence notice
  - script-permission prompts
  - the open-file failures

  Answer each one in turn.
- **The clipboard-manager bundle identifiers are unverified** (`clipboard-managers.md`). A manager that is not recognised does not get the longer settle time.

### Developer tools

- **The "Development Mode On" line could go stale (fixed in this beta).**
  - Uninstalling a development folder's extension from Settings → Extensions used to leave the line in the menu until Settings → Developer was opened.
  - Uninstalling now updates it (m3-manual row DM1).
- **Prompt cancellations leaked a little memory (fixed in this beta).**
  - `NativePanelPresenter` remembered every prompt cancelled after it was answered, and never forgot it.
  - Each prompt call now keeps its own state.
- **`pappuclip run` never performs a host call.** It records and refuses calls:
  - Network, scripts, Shortcuts and `promptText` are refused even when granted.
  - A function that depends on them can only be tested up to the call.

### Extensions

- **Submenus, and actions with no code, arrive in M4.**
  - A module action with a submenu fails to load, for example `OpenAIPrompt`.
  - A population function that offers only actions without code (shown disabled in PopClip) offers nothing yet, for example `LineCount` and `IconPreview`.
- **Some libraries PopClip bundles are missing from the helper.** `require` returns undefined for:
  - `@popclip/axios`
  - `@popclip/helpers/*`
  - `voca`
  - `superagent`
- **`.js.lzfse` package files are not read.** PopClip packages ship some libraries compressed, for example `voca.js.lzfse` and `mathjs.js.lzfse`.
- **JS-13's limits are not applied yet:** the 16 KB population input cap and module-level defaults.
- **Polyfills for newer JavaScript built-ins are not added** (JS-1). On macOS 15 before 15.4, the iterator helpers are missing.

### Built-ins

Cut, Copy, Paste, Search and Open Link are still native. The JavaScript API can now do each one's effect with the same underlying parts, but moving them would make them depend on the helper and add a round trip. Paste's and Search's conditions, and Search's engine preference, also have no public spelling. Architecture §8.7 gives the per-built-in reasons. Behaviour is unchanged.

## Deliberate differences from PopClip

PRD §8 keeps PopClip's behaviour except for a fixed set of safety exceptions. The compatibility guide (plan §9, M6 weeks 4–5) will document each one. Until it exists, this is the list:

1. **Capability consent.** An extension asks for network, scripts, synthetic input and similar at install, in a review, and runs only with what was granted. PopClip runs installed extensions without asking.
2. **Identity-bound secrets.** API keys and sign-ins belong to one installed identity, in the Keychain. They are not migrated from PopClip, and an update from another origin does not inherit them.
3. **Privacy blocks.** Secure input, password fields and blocked apps or sites are never read. An action that would need them is not offered.
4. **Clipboard ownership.** A paste holds the clipboard only for the moment it needs it, then restores it. A clipboard manager sees markers, not the transient text.
5. **Destination validation.** A result is written only after the destination is checked again at the moment of writing. When the check fails, the write is refused with a reason rather than landing somewhere else.
6. **Execution budgets.** A script that runs too long, or uses too much, is stopped. An extension that keeps doing so is suspended until it is resumed.

## Corpus findings

The pass runs every package in the frozen corpus headless (`Tests/corpus`, 381 packages). Every package counts in the denominator. A package passes only when every action it offers passes. Blocked, load-only, untested and failed packages are reported separately, and none counts as a pass (PRD §3.3).

| Outcome | Packages | What it means |
|---|---|---|
| Functional | 176 | JavaScript returned a value or asked for an effect; a URL expanded; every key combo parsed |
| Blocked | 83 | Needs something a headless run cannot have: a macOS Service (53), credentials (19), the network (5), a particular app (4), a script (1), a system service (1) |
| Load-only | 97 | AppleScript or shell script, which the pass does not execute |
| Untested | 6 | No observable effect (Reset Chat in Ollama and OpenAIChat, TestDynamic, TestPasteboard), or a population that offers only M4 actions (LineCount, IconPreview) |
| Failed | 19 | See below |

**The 19 failures:**
- **13 do not load** because of mistakes in the packages themselves, such as two config files in one package or none at all.
- **4 need missing libraries:** `ShortenLink` and `Template_JavaScript_Network` need `@popclip/axios`, `TestJavaScript` needs `superagent`, and `Slugify` needs `voca.js.lzfse`.
- **`Calculate`** needs `mathjs.js.lzfse`.
- **`OpenAIPrompt`** uses a submenu.

**Two loader bugs the pass found, both fixed:**
- A `Config.ts` that writes `defineExtension<Options>(…)` was not recognised as a module.
- A populated action that names an icon file in its own package was dropped, because the loader could not see its package.

**Reading the number.** Most non-passes are blocked or load-only. They are not failures of the runtime; a headless run cannot run them. The route to 95% is:
- bundling the missing libraries and reading `.lzfse`
- submenus and disabled actions (M4)
- running AppleScript, shell scripts, Services and Shortcuts in a harnessed session with real apps and test credentials, as PRD §3.3's definition of a functional pass allows
