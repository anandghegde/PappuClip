# PappuClip — Safety specification

| | |
|---|---|
| **Status** | Draft v0.4 |
| **Date** | 2026-09-20 |
| **Companion documents** | [PRD](../PRD.md), [Extension platform specification](extension-platform.md) |

This document holds PappuClip's safety requirements in testable form. The PRD summarises each requirement under the same ID; this document is authoritative for the detail. Every lettered statement is one obligation with one test. Priorities (P0, P1, P1.x, P2) are defined in the PRD. Sections are numbered S1–S6 so they do not collide with PRD section numbers; references such as §11.1 or BAR-17 point to the PRD, and §8.x to the extension platform specification.

---

## S1. Precedence

Every activation route — automatic appearance, the global shortcut, AppleScript, the URL scheme — passes these checks in order. No route, extension or remotely updated data file can skip a higher step.

1. **Secure input** (ACT-12). The selection is never read and the bar never appears.
2. **Hard privacy blocks and pause** (ACT-17, ACT-18). Checked before any selection read, and again at execution time (RUN-2f).
3. **Activation mode.** Appearance exclusions and per-app Automatic / Hotkey only modes. The shortcut can override an appearance exclusion; it cannot override steps 1–2.
4. **Action filtering** (§8.5). Global enablement and per-app action sets (ALM-8) can only restrict the result.
5. **Grants.** Host calls are checked against local grants at call time (SEC-7).

---

## S2. Clipboard transactions (ACT-10, ACT-16)

The simulated-⌘C fallback (ACT-9, strategy 5) is the only path on which PappuClip writes to the general pasteboard without the user asking it to.

| ID | Statement | Pri |
|---|---|---|
| ACT-10a | Before simulated ⌘C, snapshot every pasteboard item and representation. | P0 |
| ACT-10b | Skip the fallback if any representation cannot be preserved safely, or if taking the snapshot would not fit the remaining budget (§11.1). Lazily provided data counts against that budget. | P0 |
| ACT-10c | Clipboard transactions are serialized; a second never starts while one is open. | P0 |
| ACT-10d | Ownership is tracked with `changeCount` plus transaction state. A count change alone does not prove that the simulated copy caused it. | P0 |
| ACT-10e | Restore the snapshot only while the temporary state is still attributable to this transaction. | P0 |
| ACT-10f | Never overwrite an intervening user or app copy, or an ambiguous state. Abort the read and leave the pasteboard as found. | P0 |
| ACT-10g | Never interpret an unrelated copy as the selection. | P0 |
| ACT-10h | Mark app-owned writes with `org.nspasteboard.TransientType` and `ConcealedType` where supported, and suppress the alert sound where feasible. | P0 |
| ACT-10i | Verify clipboard-manager interoperability against a named list of managers and publish the results. Make no claim that another app's copy write is invisible. | P0 |
| ACT-10j | Synthetic copy does not run on the automatic path when the app's detection policy disallows it (ACT-11a), including every app with no policy, or while PopClip is running (ONB-6). | P0 |
| ACT-16a | A newer selection, a focus or context change, a privacy-state change or the hard cutoff (§11.1) invalidates pending detection work. | P0 |
| ACT-16b | A late completion cannot show a bar, supply action input or restore over a newer clipboard write. | P0 |
| ACT-16c | Delayed synthetic-copy responses and timeout cleanup obey ACT-10e–g. | P0 |

---

## S3. Action lifecycle and destination verification (RUN-1–5)

These rules apply to built-ins, legacy actions, native actions and host API calls. They govern PappuClip-controlled effects. Arbitrary scripts, Services and Shortcuts can perform external effects outside these guarantees, which capability consent must disclose (S4).

### Snapshot

| ID | Statement | Pri |
|---|---|---|
| RUN-1a | At invocation, capture an immutable input snapshot plus the originating app and process, window, focused control and selection context. | P0 |
| RUN-1b | Track later changes separately. Never silently retarget an in-flight action to the current app. | P0 |
| RUN-1c | A focus transfer into an explicitly opened PappuClip surface is tracked as such, not mistaken for a new destination. | P0 |

### Verification tiers

| Tier | Evidence required | Applies when |
|---|---|---|
| **Accessibility-verified** | Same process, window and focused element as the snapshot; the element is editable; the selected range and text still match | The selection was read through Accessibility (ACT-9 strategies 1–3) |
| **Quiescence-verified** | Same frontmost process and window as the snapshot; the event tap has seen no mouse-down, key-down or scroll outside PappuClip's own surfaces since the snapshot; elapsed time is within a short window (initial value 3 s; M0 spike 6 sets it); the app's detection policy allows the tier | The selection was read without Accessibility (strategies 4–5), so the range cannot be compared |
| **Unverifiable** | Anything else | — |

The quiescence tier exists because the most common legacy extension — a fast text transformation with `paste-result` — would otherwise be blocked in exactly the Chromium and Electron apps that G4 targets. It relies on the event tap PappuClip already owns: if the user has not touched the keyboard or mouse and the same window is frontmost, the selection is where it was.

| ID | Statement | Pri |
|---|---|---|
| RUN-2a | Every host-controlled cut, insertion, replacement or synthetic input is preceded by destination verification at one of the tiers above. | P0 |
| RUN-2b | Accessibility-verified and quiescence-verified destinations permit automatic mutation (`paste-result`, `pasteText`, cut, key presses). | P0 |
| RUN-2c | An unverifiable destination blocks automatic mutation. The completed result is presented for explicit copy instead. | P0 |
| RUN-2d | A blocked mutation never auto-copies the result over a newer clipboard value. | P0 |
| RUN-2e | Explicit Replace and Insert controls (BAR-17) re-verify at click time under RUN-2a. When verification fails they are disabled with an explanation; Copy remains available. | P1 |
| RUN-2f | Privacy rules (S1, steps 1–2) are rechecked at execution time. | P0 |
| RUN-2g | Any input event outside PappuClip's surfaces, an app switch, a window change or expiry of the time window downgrades a quiescence-verified destination to unverifiable. The key-down tap stays installed for the life of an invocation that may mutate text (ACT-19). | P0 |
| RUN-2h | A detection policy (ACT-11) can disable the quiescence tier for an app. No policy can enable mutation at the unverifiable tier. | P0 |

### Cancellation

| ID | Statement | Pri |
|---|---|---|
| RUN-3a | Cancellation immediately invalidates the invocation. | P0 |
| RUN-3b | Host-effect requests from an invalidated invocation are rejected. | P0 |
| RUN-3c | Late results and errors are discarded: no paste, no copy, no success indication. | P0 |
| RUN-3d | Owned work is stopped where supported. Owned script processes are terminated where safe, and delegated automation is asked to cancel. | P0 |
| RUN-3e | The UI says when an external action may already have completed or cannot be stopped. Rollback of external effects is never promised. | P0 |
| RUN-3f | Pause (ACT-18) and revocation (SEC-4, SEC-5) invalidate affected invocations in the same way. | P0 |

### Undo and regression scenarios

| ID | Statement | Pri |
|---|---|---|
| RUN-4 | Text replacement participates in the target app's native Undo where supported, preferably as one edit. Document unsupported targets; do not implement an unsafe global Undo by replaying stale text. | P0 |
| RUN-5 | Regression scenarios cover: slow translation in Notes followed by switching to Terminal; editing the source while a result is pending; changing the selection; closing the source window; entering secure input; cancellation immediately before completion; a new selection racing an older detection; and a quiescence-verified paste with and without an intervening input event. Assert no wrong-destination mutation, no late success after cancellation and no stale bar. | P0 |

---

## S4. Consent and capabilities (EXM-5, EXM-15, SEC-4, SEC-7)

Consent has two levels. The aim is that a default-deny prompt is rare enough to be read. If every extension, including a web search, raised one, users would learn to click through it.

| Capability | Level | What the user is told (example) |
|---|---|---|
| URL action whose host is fixed in the config | Listed | "Sends the selected text to example.com when you click it" |
| URL action whose host comes from an option | Listed | "Opens a URL you configure, containing the selected text" |
| Key Press action with fixed combinations | Listed | "Presses ⌘A in the current app" |
| Service or Shortcut action, by name | Listed | "Runs your Shortcut 'Add to Journal' with the selected text. The shortcut can do whatever Shortcuts allows" |
| Sandboxed JavaScript: read the input, return text, copy, paste, show results | Listed | "Reads and replaces the selected text" |
| `dynamic` | Listed | "Runs each time the bar appears, without network access or secrets" |
| `network` limited to `networkHosts` (SEC-6) | Listed | "Sends data to api.example.com" |
| JavaScript that opens URLs, in a registry package whose reviewed capability record names the hosts | Listed | "Opens pages on example.com containing the selected text" |
| `network` without `networkHosts` | **Gated** | "Can send the selected text to any server" |
| Script-driven synthetic input (`pressKey`, `pressKeys`) and `performService`, `share` | **Gated** | "Can type and press keys in the current app" |
| Shell Script and AppleScript actions; the `script` entitlement | **Gated** | "Runs a script outside the sandbox, with your user permissions" |
| Unreviewed JavaScript whose reachable sensitive host methods cannot be bounded | **Gated**, once per extension | Lists the reachable methods |

| ID | Statement | Pri |
|---|---|---|
| EXM-5a | Every install route (registry, file, selected snippet, import, generated action, sync) shows the extension's origin and effective capabilities in plain language before any of its code runs. | P0 |
| EXM-5b | Effective capabilities are computed under SEC-7, not read from manifest entitlements alone. | P0 |
| EXM-5c | Listed capabilities are approved by the single install confirmation, which names them. | P0 |
| EXM-5d | Each gated capability needs its own approval, defaulting to "Don't Allow", and says where the code may act outside the JavaScript sandbox. | P0 |
| EXM-5e | A signature or registry review never moves a capability from gated to listed. For registry packages the signed capability record bounds which host methods the extension may call; the host enforces that bound at call time rather than trusting it. | P1 |
| EXM-5f | Unreviewed JavaScript whose reachable sensitive host methods cannot be bounded is gated once per extension, listing those methods. | P1 |
| EXM-5g | The bundled built-ins are approved by installing the app. Onboarding states that Search sends the selected text to the chosen search engine when clicked. A duplicated built-in keeps that approval; an edited one becomes user-generated and follows EXM-5a–f. | P0 |
| EXM-5h | An update that expands effective capabilities shows the delta and needs approval before activation (§9.4). | P1 |
| EXM-15a | When several extensions arrive together (Import from PopClip, configuration import, sync), one review sheet lists them all with their capabilities. | P1 |
| EXM-15b | Extensions with only listed capabilities are approved together by one confirmation, after the list is shown. | P1 |
| EXM-15c | Each extension with a gated capability has its own switch, off by default. | P1 |
| EXM-15d | Unapproved extensions stay installed but disabled, run no code including population functions, and can be approved later from Extension Info. | P1 |
| SEC-4a | Users can inspect and revoke grants in Extension Info. | P0 |
| SEC-4b | Revoking execution approval disables the extension and invalidates its pending host work (RUN-3f). | P0 |
| SEC-7a | For non-JavaScript action types, effective capabilities include the action type, delegated automation, controlled apps and known destinations. | P0 |
| SEC-7b | For JavaScript, effective capabilities also include reachable host methods. Every host call is checked against local grants at call time; a call outside the grants fails and is reported in the Debug Console. | P1 |
| SEC-7c | Where effects cannot be determined, disclose and seek consent for the broader reachable capability rather than claiming a narrow sandbox. | P0 |
| SEC-7d | New or expanded sensitive access requires reapproval. Denied access cannot be obtained through another action type. | P0 |

---

## S5. Identity, grants and secrets (SEC-8)

| ID | Statement | Pri |
|---|---|---|
| SEC-8a | Grants and Keychain access are bound to extension identity, instance and trusted provenance, never to display name or identifier alone. | P0 |
| SEC-8b | For registry code, identity is the signed namespace and publisher ownership record. For local code, it is the approved origin and content digest. | P0 |
| SEC-8c | An unverified content or provenance change requires approval before the changed code executes. | P0 |
| SEC-8d | A matching name alone never replaces an installed extension. A matching identifier from another or unverifiable origin installs separately with a new local identity, unless the user approves a trust transition (EXM-2). | P0 |
| SEC-8e | A trust transition requires explicit approval. Reauthentication is the default; secrets do not move. | P1 |
| SEC-8f | Secret migration requires a separate approval naming source and destination, plus a reviewed ownership and migration mapping. | P1 |
| SEC-8g | A package's `replaces` claim alone authorises nothing. | P1 |
| SEC-8h | Sync, configuration import and rollback never transfer secrets to a different identity and never restore grants (SYN-3, CFG-3, EXM-13). | P1 |

---

## S6. Extension isolation and remote data (SEC-1–3, SEC-5, SEC-6, SEC-9)

The tiers below describe execution mechanisms, **not trust levels**. Signing establishes provenance, not harmlessness.

| Tier | What the extension contains | Install behaviour |
|---|---|---|
| 0 | URL, Key Press, Service or Shortcut actions | Listed capabilities; one install confirmation |
| 1 | Sandboxed JavaScript with no entitlements | Listed when a registry capability record bounds its host methods; otherwise gated once (EXM-5f) |
| 2 | JavaScript with `network`, `dynamic` or `script` | `dynamic`, and `network` with `networkHosts`, are listed; `network` without hosts and `script` are gated |
| 3 | Shell Script or AppleScript actions | Gated, with an outside-sandbox warning; the registry requires a written shell-action rationale |

| ID | Statement | Pri |
|---|---|---|
| SEC-1a | JavaScript runs in a separate helper process with no filesystem entitlement and no network entitlement. | P1 |
| SEC-1b | Each extension has its own JavaScript virtual machine and global object. No object, module cache or timer is shared between extensions. Option values and secrets are passed per invocation, to the owning extension only. | P1 |
| SEC-1c | `XMLHttpRequest` is carried out by the host process, which enforces the `network` entitlement, the https rule (JS-8) and `networkHosts` (SEC-6). | P1 |
| SEC-1d | A crash or hang in extension code never takes down the bar. The helper restarts; the crash is attributed to the extension whose code was running, and an extension that repeatedly crashes the helper is suspended with an explanation. | P1 |
| SEC-2 | Extension code has watchdog limits on run-away CPU and memory. User-initiated actions have no fixed timeout, because the user can cancel them. | P1 |
| SEC-3 | Secrets live only in the Keychain, are never readable during population, and are never written to logs. | P1 |
| SEC-5 | The app fetches a signed revocation list with its update checks. A revoked extension version is disabled and the user is told why. | P1 |
| SEC-6 | **Native addition:** an optional `networkHosts` list in the manifest. When present, requests to other hosts fail and consent names the hosts. When absent, network access is gated as "any server". It is required for packages in our namespace that use `network` (PUB-4). For a dual-published package whose config lacks it, the registry entry may supply it, and the signed manifest carries it. | P1 |
| SEC-9 | Data fetched outside an app release — detection policies (ACT-11b), the revocation list (SEC-5) and the registry index — is signed with a pinned key and versioned with rollback protection. It is declarative only. It cannot loosen secure-input handling, hard privacy blocks, pause or user rules; cannot enable synthetic copy or a mutation tier in an app the user has restricted; and cannot grant capabilities. Every endpoint is disclosed (§11.3). | P1 |
