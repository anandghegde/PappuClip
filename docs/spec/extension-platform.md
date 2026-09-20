# PappuClip — Extension platform specification

| | |
|---|---|
| **Status** | Draft v0.4 (split from PRD v0.3 §8 and Appendices A–B) |
| **Date** | 2026-09-20 |
| **Companion documents** | [PRD](../PRD.md), [Safety specification](safety.md) |

This document specifies the extension format and runtime. Section numbers continue the PRD's §8, so cross-references written as §8.x resolve here. References to any other section (§7, §9.3, §11.1) and to IDs not defined here (BAR-17, EXM-2, RUN-3) point to the PRD; SEC IDs and §S sections point to the safety specification. Priorities (P0, P1, P1.x, P2) are defined in the PRD.

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
| `networkHosts` | Array | Native-only. The hosts the extension's network requests may reach; requests to other hosts fail (SEC-6) |

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
| JS-8 | Network: `XMLHttpRequest` works only with the `network` entitlement. Named hosts must use https; plain http is allowed for localhost, numeric IPs, unqualified names and `.local`. The host process makes the request on the extension's behalf (SEC-1c) and enforces `networkHosts` (SEC-6). | P1 |
| JS-9 | Bundled libraries available to `require`, at the same major versions as PopClip: axios, buffer, case-anything, content-type, dom-serializer, emoji-regex, entities, fast-json-stable-stringify, fast-plist, htmlparser2, js-yaml, linkedom, linkifyjs, oauth-1.0a, rot13-cipher, sanitize-html, sucrase, turndown, valibot. All are permissively licensed; confirm each licence before bundling. | P1 |
| JS-10 | Module resolution: `./` and `../` are relative to the current file; other specifiers try the package root and then the bundled libraries; absolute paths and paths escaping the package are invalid; `.js`, `.ts` and `.json` are supported; results are cached. `import` and `export` are converted to `require`. | P1 |
| JS-11 | Inline and file scripts are wrapped in an async function. A returned string goes to `after`. A thrown error shows failure. An error message starting with `settings error` or `not signed in` opens the settings sheet. | P1 |
| JS-12 | Module extensions export through `defineExtension(obj)`, a default export, named exports or CommonJS. Fields: `options`, `auth`, `actions` (array or population function), `action`, `submenu`, `test`. Module actions use `code`; an action may be a bare function. | P1 |
| JS-13 | Population functions need the `dynamic` entitlement and run each time the bar appears. During population there is no network, no `popclip` methods, no timers and no access to secrets. | P1 |
| JS-14 | TypeScript files are transpiled at load time with no type checking. | P1 |
| JS-15 | The bar shows a spinner while asynchronous work runs, with mouse and keyboard cancellation. Cancellation invalidates the invocation and its outstanding host calls under RUN-3, even if a promise resolves later. | P1 |
| JS-16 | **Safety addition:** population shares the target budget in §11.1. Initial ceiling: 15 ms per function and 30 ms aggregate against a warm helper (JS-19), IPC included, also capped by the time remaining before rendering must start. If the helper is not warm, skip population for that appearance instead of paying its startup. Skip work that cannot fit, discard late results, and report the omission/timing without selection content. Never move visible buttons when late population completes. PopClip documents no limit. | P1 |
| JS-17 | **Native addition:** `pappuclip.showResult(text, { format })`, where `format` is `text` (default) or `markdown`, presents BAR-17 without an implicit clipboard write. The panel retains the invocation's destination context and obeys cancellation, safe rendering and focus rules. This does not change legacy `showText`. | P1 |
| JS-18 | **Native addition:** `await pappuclip.promptText({ label, placeholder, defaultValue })` opens one labelled text field with Submit/Cancel during an explicitly invoked action, never during population. `label` is required; the other strings are optional. Submit resolves to the entered string (including empty); Cancel, Esc or close cancels the invocation under RUN-3. No arbitrary HTML/UI, secret-field use or automatic persistence. The prompt is keyboard/VoiceOver accessible; after submission, any result mutation still revalidates the original destination. | P1 |
| JS-19 | **Warm helper:** while at least one enabled extension declares `dynamic`, the helper process and those extensions' contexts are created at launch and re-created after a crash or memory-pressure teardown. Mouse-down in an app that is not blocked or paused triggers a readiness check, so warming overlaps the user's drag instead of the budget that starts at mouse-up. Warming loads modules but reads no selection and calls no population function. With no `dynamic` extension enabled, the helper starts lazily on first use. The idle CPU target (§11.1) still applies. | P1 |

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

Moved to the [safety specification](safety.md): consent levels and SEC-4/SEC-7 in §S4, identity and secrets (SEC-8) in §S5, and isolation, `networkHosts` and remote data (SEC-1–3, SEC-5, SEC-6, SEC-9) in §S6.

### 8.13 Signing

P1. Extensions published through the registry are signed by its release workflow (§9.3). The signature covers a manifest of every file's hash plus the identifier, the version and the reviewed capability record, including any `networkHosts` the registry entry supplies. Public keys are pinned in the app, and the scheme supports key rotation. The private key is a CI secret in a protected environment that only the release workflow on the default branch can use, behind a required maintainer approval. That is weaker than a dedicated signing service; rotation and revocation (SEC-5) are the recovery path, and the choice is revisited if the registry grows. Because packages come from static hosting, the app refuses a version lower than the installed one except for a user-initiated rollback (EXM-13). The signature file uses its own reserved name so it never collides with PopClip's `_Signature.plist`.

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
