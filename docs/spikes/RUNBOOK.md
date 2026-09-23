# M0 runbook — what is left, and who has to do it

State on 2026-09-21. One Mac (Mac16,10, macOS 26.4.1). The owner has switched SpikeLab on under **Accessibility**
and nothing else, and the grant has survived two rebuilds (spike 2's check, and a build with new code after it). What is left is listed here as commands to run,
almost all of it needing hands on the mouse and eyes on the screen.

## Where the six spikes stand

| Spike | Code | Runs | Report | Blocked on |
|---|---|---|---|---|
| 2 · taps and permissions | done | 4, nothing granted; 2, Accessibility, unwatched | [`spike-2-taps.md`](spike-2-taps.md), running; one grant, ACT-19 and the rebuild are answered | a watched run; the stall; Input Monitoring as well |
| 1 · panel above fullscreen, focus | done | 1, nothing granted, unwatched | none | eyes on the screen |
| 3 · selection strategies per app | done | none | none | one run per app |
| 4 · switching on the AX tree | done | none | none | one run per Chromium or Electron app |
| 6 · clipboard and quiescence | done | 3, nothing granted | [`spike-6-clipboard.md`](spike-6-clipboard.md), running | someone typing for the `epoch` part; a selection in each app for `live` |
| 5 · JavaScript helper | done | 5 | [`spike-5-js-helper.md`](spike-5-js-helper.md), answered with a design change | nothing |

Spikes 3 and 4 have no result file. With nothing granted both stop at their first line ("Accessibility is not
granted"), which is all that has been exercised of spike 4; expect to find bugs on its first real run, as spike 6's
first runs did. Spike 3 has been through once with the grant, as a check that the grant was seen, with nothing
selected and a terminal (Ghostty) in front; it ran to the end and read nothing by either AX strategy. The file was
not kept.

Spike 1 has one file, `Tests/results/spike-1-panel/20260920T143907-macOS26.4.1-arm64.json`: nothing granted, a
normal Space, nobody watching. All 16 panels were reported on screen by AppKit and the window server, none took
activation, and showing the pre-built panel cost p95 1.9 ms over 30 cycles (p99 4.0 ms) against the 10 ms ceiling.
It does not say which panels could be *seen*, which is the question, and its focus part did not run. The app in
front was another project's test fixture with no bundle identifier, hence `frontmost=unknown` in the file.

**The Mac was shared on the day.** A test job of another project ran on it from 13:47 UTC, starting apps that come
to the front and, in one script, pressing keys in file panels. Every run after that time was made alongside it:
all of spike 5's and spike 6's, spike 2's fourth, and spike 1's. The reports say so where it matters. Make the
hands-on runs below with nothing of that kind going on, and repeat one spike 5 and one spike 6 run on the idle
machine before their timings go into a budget.

## Before any of it

1. `Scripts/build.sh`. The grant is tied to the signing certificate ("PappuClip Development",
   `Scripts/setup-dev-signing.sh`) and has survived a rebuild once. It will not survive a new certificate, so do
   not run `setup-dev-signing.sh` again without a reason; if a build ever comes out ad-hoc signed, fix the signing
   and do not grant the ad-hoc build.
2. Accessibility is on for SpikeLab. Do **not** add Input Monitoring yet: spike 2 still wants a watched run with
   one grant.
3. Always start runs with `Scripts/run-spike.sh`, never the binary from a shell: a shell-started run describes the
   terminal's permissions (see `Tests/results/README.md`).
4. Put what was true into `--state "…"` and, afterwards, anything you saw that the log cannot know (prompts, panels,
   stutters) into the report. The result files hold counts, lengths and times, and nothing of what was on your
   clipboard or in your selection.

## The runs, in the plan's order

**Spike 2** — see the numbered list at the end of [`spike-2-taps.md`](spike-2-taps.md). About ten minutes. That the
active taps are available with Accessibility alone, which every later spike leans on, is already answered; what is
left needs someone clicking and someone watching for prompts.

**Spike 1** — one run per setting: a normal Space, a fullscreen app, a second Space, Stage Manager, a second display.

    Scripts/run-spike.sh spike-1-panel --state "Accessibility only; fullscreen Safari"

During the countdown switch to the app, click into a text field and select some words. Numbered orange panels appear
one at a time; **write down every number you saw**, because the log only knows what it asked for, not what was
drawn. Options: `matrix`, `focus`.

**Spike 3** — one run per Tier A gating app (PRD §11.5; fifteen of them). During the countdown select a sentence in
the app and note how many characters.

    Scripts/run-spike.sh spike-3-selection --state "Accessibility only; Safari 26, article text, 84 characters"

Off by default, to be switched on deliberately with `--enable`: `appleScript` (raises an Automation prompt the first
time) and `syntheticCopy` (puts the selection on the clipboard for a moment, then puts back what was there). The
others are `scriptedSelect` and `axEnable`.

**Spike 4** — one run per Chromium or Electron app. Quit and reopen the app first, make sure VoiceOver is off, and
while the log says the tree is held on, move and resize the window and watch for a slide, a jump or a stutter.

    Scripts/run-spike.sh spike-4-ax-enable --state "Accessibility only; Slack 4.x, cold"

Options: `both`, `cycles`, `hold`.

**Spike 6, the rest** — two parts.

    Scripts/run-spike.sh spike-6-clipboard --state "Accessibility only; typing during the epoch window"

When the log says "Type, click and scroll in another app", do so for the ten seconds. This settles
`epoch.countsRealInput` and `epoch.leavesOutOurOwnEvents`, and it is also the run that shows whether the crash
described in the spike 6 report is gone: an earlier build died in exactly this window, and no run since has had
input in it. If SpikeLab disappears, the report is in `~/Library/Logs/DiagnosticReports/SpikeLab-*.ips`.

    Scripts/run-spike.sh spike-6-clipboard --enable live --state "Accessibility only; live: Safari 26"

`live` sends ⌘C to the frontmost app five times, so select a sentence during the countdown and keep your hands off.
It snapshots the clipboard first and puts it back. One run per app, from the Tier A lists of PRD §11.5: start with
Safari, Chrome, VS Code or Slack (Electron), Terminal and Word, the last because of its stray-copy issue. These give
the expected count delta and the copy-latency tail that the drain window has to come from.

**Then** Input Monitoring on as well, and spike 2 once more with that state named.

## After the runs

Still owed for the M0 exit (implementation plan §3), none of it started, most of it waiting on spikes 1, 3 and 4:

- Reports for spikes 1, 3 and 4, and the "running" reports for 2 and 6 brought to an answer.
- The per-app contents of `Resources/DetectionPolicies/detection-policies.json` and the final Tier A gating
  list (spike 3). The file and its store exist; what is missing is every value a run would set.
- Revised stage budgets, hard cutoff and quiescence window (spikes 3 and 6).
- Spike 5's changes are written into `docs/architecture.md` (§10.1, §10.2, §10.6, §10.7), the two proposals among
  them marked as proposals. Spike 6's are written in too, and §5 is now the design as built: the state machine is
  redrawn with `Settling` and a post-restore `Watching`, and the "not yet designed in" list at the end of it is
  gone. PRD §11.1 does not yet carry spike 5's proposed memory budget (60 MB warm, 250 MB watchdog limit).
- The one decision that did not need more data — a foreign write that lands before the app's copy, spike 6's
  "first-writer hole" — is made, in that report's "Consequences": all three candidates, and the residue recorded
  rather than claimed closed. What is still owed on the clipboard is measurement, not decisions: spike 6's `live`
  run for per-app copy latency and the expected-delta ranges, and ACT-10i's named clipboard-manager matrix.
- The §19 items and the M3–M5 re-estimate. (The licence is decided: MIT, PRD §13.)
- macOS 15 and the current beta: no run of any spike has been made on either.

## Started ahead of the M0 exit

While the runs above wait on the grant, the parts of M1 that need no permission and no spike figure have been
built in the package:

- **Week 1.** `AttemptID` and `InvocationID`, the attempt clock and the budget table (`PappuCore`); the tap
  service with its health monitor and the reference-counted key-tap lease, the hotkey registration, and the
  gesture recogniser with its replayable corpus (`PappuSelection`, `Tests/gestures/`). The corpus is synthetic so
  far; recording real gestures needs the tap.
- **Week 2, the gate half.** `ReadPermit` and `PrivacyGate` with its reason codes, and pause with an absolute
  expiry that survives relaunch (`PappuCore`), plus the `IsSecureEventInputEnabled` probe (`PappuSelection`).
  That closes ACT-17a and ACT-18, and the half of ACT-5 that says what the shortcut may not override. The AX
  actor, which reads the other half of ACT-12, `ActivationCoordinator`, which is where every route meets the
  gate, and the watchers that retire an attempt from outside it have since been built as well (all three
  below). What is left of week 2 is strategies 1–3; they need a live AX tree to be worth writing, so they
  wait on the grant and on spikes 3 and 4.
- **Week 2, the policies.** `DetectionPolicy`, `DetectionPolicies` and `DetectionPolicyStore`
  (`PappuSelection`) over `Resources/DetectionPolicies/detection-policies.json`. What the file *says* is
  spike 3's and spike 4's output; what it *may* say is not, so the mechanism was buildable now and is:
  the strategy chain per route, the restrictive merge, the user's ceilings, prefix matching for identifier
  families, and the default that refuses synthetic copy on the automatic path for an unlisted app. Closes
  ACT-11a and ACT-10j, and carries the halves of ACT-9, RUN-2h, SEC-9 and ONB-6 that are decided by policy
  rather than by the code that reads or copies. The shipped file holds the default, the `copiesLineWhenEmpty`
  flags ACT-11a names by hand, and provisional `axEnable` kinds taken from each app's family; no value in it
  comes from a measurement, and its `note` field says so.

Spike 2 has since answered the tap question (active taps on the one grant, key tap install far under its
ceiling), and `EventTapService` with `KeyTapLease` is built on that answer (`PappuSelection`; ACT-8, ACT-15 and
ACT-19 have tests). The package's tests drive it through a fake installer. The real one, `SessionTapInstaller`,
is run on a live session by a seventh SpikeLab entry that is not a spike and needs no hands:

    Scripts/run-spike.sh check-tap-service --state "Accessibility only"

It posts F13 key-downs and ⌃⌥⌘F16 presses that its own taps and its own shortcut swallow, and no mouse events.
First result: `Tests/results/check-tap-service/20260920T184024-macOS26.4.1-arm64.json`, all confirmed; a lease costs
p50 0.13 ms, max 4.7 ms through the service against the 10 ms ceiling. Not yet exercised on a real session: a tap
macOS itself switched off, and pointer events from a real mouse (the run counted none, nobody was at it).

The other two week-1 routes have since been built, both in `PappuSelection`:

- The global shortcut (ACT-5, ACT-19). `HotkeyShortcut` holds the combination and enforces the rule that it carry
  ⌃, ⌥ or ⌘ or be a bare function key; `HotkeyService` registers one at a time over a `HotkeyRegistering` seam and
  puts presses on an `AsyncStream`; `SystemHotkeyRegistrar` is the Carbon implementation, `RegisterEventHotKey` on
  the main thread behind a `@MainActor` table. It is not a tap and needs no permission, which is why it is the one
  route still standing when the grant is missing (ONB-4).
- The health notices (ACT-15). `TapHealthMonitor` calls `EventTapService.checkHealth()` on each of the three
  moments a tap can have gone away with nobody in the callback to say so, and `WorkspaceHealthTriggers` is the
  `NSWorkspace` implementation: wake, session-became-active, application-activated. The monitor is deliberately
  thin — no throttling, since a check is cheap and the notices are rare.

Both are driven by fakes in the package's tests (`FakeHotkeyRegistrar`, `FakeHealthTriggers`), and `check-tap-service`
now exercises the real ones as sections 6 and 7: it registers the shortcut, posts it, clears it and confirms the key
goes back, then reports how many workspace notices arrived during the run. That last one is `.info`, not a claim:
nothing in the run sleeps the Mac or switches the session, so it counts whatever happened. The recorded result above
predates both sections, so the check wants running again.

The AX actor is built, ahead of the strategies that will run on it (`PappuSelection`). `AXActor` is a global actor
on a dedicated serial `DispatchQueue`, because every Accessibility call blocks on the app it asks and must stay off
the cooperative pool (architecture §14). `AXWorld` is the seam, in value types only — no `AXUIElement` and no
CoreFoundation type leaves the module — and `SystemAXWorld` is its one implementation, carrying the `AXError`
mapping spike 3 arrived at. On top sits `AXFocusProbe`, the mouse-down pre-work of architecture §4.3: the focused
element's role and subrole, the role under the pointer, and a baseline range that is read only against a
`ReadPermit`. Two properties are structural rather than promised: `AXAttribute` is a closed list with a
`carriesText` flag, so a test can assert the probes read no attribute that can hold text, and the focused element
never leaves the actor, so a baseline can only be read for the process the gate judged. That closes the AX half of
ACT-12 and gives ACT-14 its signals; weighing them is `ActivationCoordinator`'s job, which is built (below).

Its sixteen tests all drive `FakeAXWorld`, so what is *not* covered is `SystemAXWorld` itself — the decoding by
`CFGetTypeID` and the fault mapping against a live tree. Spikes 3 and 4 walk the same paths, so the grant session
that runs them is the first real exercise of it; if they leave gaps, a `check-ax-probe` entry alongside
`check-tap-service` is the way to close them.

`ActivationCoordinator` is built, ahead of the strategies and the bar it sits between (`PappuSelection`). It is
the one place an attempt lives: the mouse tap through the gesture recogniser, the shortcut and, later, the
scripting routes all arrive at the same steps — the mouse-down pre-work, the gate, the app's detection policy,
the strategy chain, and then ACT-14's weighing in `ActivationRules.verdict(for:)`. Nothing downstream decides
whether a bar appears; the coordinator does, and says so by minting an `AppearancePermit` that `BarPresenting`
cannot be called without, which is how ACT-16b stops being a rule and becomes a type. Every attempt lands in a
bounded `AttemptTrace` of codes, identifiers and counts for DIA-2.

Its twenty-six tests drive fakes for all three seams — the strategy chain, the bar and the long-press timer —
and a manual clock. What they are really about is order: a newer gesture, a newer press, a focus change, another
app coming forward, a tap interruption and the 700 ms cutoff each retire an attempt whose read is still out, and
the fake reader can run a test's own code *inside* the read to arrange exactly that. Two seams are still not
attached: the strategies (the reader is a fake) and the bar, which is built (below) but not yet wired to it.
`SystemActivationTiming`, the long-press timer it ships with, is a `Task.sleep` and is not covered by a test; the
fake one stands in for it everywhere.

The watchers that call `invalidate(_:)` from outside are built too, as one component, `AttemptWatcher`
(`PappuSelection`). It holds an `AXObserver` on the app the attempt is about and takes `NSWorkspace`'s activation
notices, and raises an `AttemptNotice` that names the attempt it was watching; `ActivationCoordinator.watch(_:)`
is the one consumer, as `run(_:)` is for the tap. Both notices have the same trap in them — the tap sees mouse-up
before the app does, so the user's own gesture makes the app settle the selection and activate itself *after* the
attempt has begun — and each has a rule for it: a selection notice counts only once the read is back, an
activation notice is filtered by pid. Twenty tests cover the rules; the two implementations,
`SystemAXObserver` and `WorkspaceActivationWatcher`, are not covered by any, because both need a live session.
**Two things a grant session should watch for**: that the `selected-text-changed` notice for a drag really does
arrive before the read that follows it answers (the rule above rests on it, and a `check-ax-observer` entry
alongside `check-tap-service` is the way to measure it), and whether registering with an app costs anything
noticeable in Chromium and Electron apps, which is spike 4's territory. The third source of invalidation, a
privacy state that changes mid-attempt, is still unwired.

`ClipboardBroker` is built — M1 week 3, and the last piece of strategy 5 (`PappuSelection`). It is the only code
in PappuClip that writes to the user's clipboard, and every rule in it comes from something spike 6 measured: the
settle, because the change count moves on the clear and not on the write; the snapshot on a thread it can walk away
from, because a hung lazy provider cannot be cancelled; the count check compared against what `clearContents()`
returns, because the gap before it cannot be closed and can only be known; and the drain that outlives the answer,
because an app that was merely slow will land its copy with nobody watching. `ClipboardTiming` holds the numbers in
one place, provisional until the `live` run, and `CopyDelta` is the one clipboard value that lives in a detection
policy, because it is the only one whose merge can only take away (SEC-9). A transaction cannot start without a
`SyntheticCopyPermit`, which only `DetectionPolicyStore` can mint, so ACT-10j is a call that does not compile rather
than a check somebody has to remember. That closes ACT-10a–h, the broker's half of ACT-10j, the synthetic-copy half
of ACT-16c, and strategy 5 of ACT-9.

Its fifty-odd tests drive `ScriptedPasteboard`, which is pasteboard, clock, scheduler and ⌘C poster in one, so a
test writes an interleaving as a list of events and a fake clock runs it in microseconds. The last of them is the
one worth naming: 160 seeded interleavings of copies, foreign writes, bare clears and keystrokes, asserting on every
one that at most one write reaches the user's clipboard, that it is the snapshot and marked, that no ambiguous
outcome writes at all, that a destroyed write in the restore gap is reported exactly when one happened, and that no
string anywhere inside the record is the clipboard's. It also asserts that all eleven outcomes and safety events are
reached, so a generator that stops exploring fails instead of passing quietly.

What no test covers is the three real implementations — `SystemPasteboard`, `SystemSyntheticCopy` and
`SystemClipboardScheduling` — because posting a ⌘C needs the post-event grant and a real app to receive it. A
`check-clipboard-broker` entry alongside `check-tap-service`, running one transaction against a scratch text field,
is the way to close that, and it is the same session that spike 6's `live` option wants.

`InputEpoch` now has its first consumer: the broker takes a listen-only key-tap lease for the length of its window
and refuses to attribute anything when it cannot (`inputUnwatchable`). That is architecture §19 item 1's
recommendation built, and ACT-19's own wording still has to catch up with it. Validating the epoch against a real
tap still waits for spike 6's `epoch` run.

The bar is built — M1 week 4, and the whole of `PappuSurfaces`. Its shape comes from one fact about CI: there is no
window server there, so an `NSPanel` cannot even be *constructed* — the test process traps on `init`. Every rule
therefore lives in a value type that takes no AppKit, and AppKit sits in one file, `BarPanel.swift`, that no test
touches. `BarLayout.place` is the placement, a pure function from an anchor, measured widths, the metrics and a list
of displays to a frame, a side, an arrow and how many buttons fit; `BarKeyboardMode` is compact keyboard mode;
`BarDismissal.reason(for:barFrame:)` is the pointer half of BAR-10, a function of an event and a rectangle with no
clock in it; `BarAppearance.resolve` maps the colour preference and the three accessibility settings onto a
background, a highlight, a border and a motion; `BarFeedback` holds the spinner, "Copied", the tick and the shaking
X and refuses to say the same thing twice running. `BarController` is the one `BarPresenting` and is the seam
`ActivationCoordinator` has been calling into since week 2. That closes BAR-1, 2, 3, 6, 8a, 9a, 10, 11, 12a and 14,
and the halves of ACT-5, ACT-6a and ACT-19 that are the bar's.

Two things about it are worth naming because they are not obvious from the diff. **It has two isolation domains.**
Key presses arrive on the event tap's thread and must be answered at once (ACT-15), so the controller keeps what
the handler needs behind a `Mutex` and the main actor catches up afterwards; a handler that dismisses clears
`isUp` *inside* the lock, so a second key arriving behind the dismissal passes through to the app instead of being
eaten by a bar already on its way out. And **everything in the module is in top-left screen coordinates** — what
CGEvent and `AXBoundsForRange` give — with AppKit's flipped space entered exactly once, in `BarPanel.swift`.

Its ninety-seven tests drive fakes for all six seams — the window, the content provider, the invoker, the displays,
the appearance settings and the key tap. What none of them covers is `BarPanel.swift` itself, for the reason above:
`canBecomeKey` returning false, the collection behaviour, the vibrancy view, the arrow's path and the tooltip are all
checked by hand. `docs/checklists/voiceover-bar.md` is that check, written and **not yet run** — it needs a bar on a
screen, so it waits on the grant and on spike 1, whose matrix also settles `BarPanelConfiguration.bar` (the value says
**provisional** in its own doc comment). Two other gaps are recorded rather than papered over: **pointer departure**,
which BAR-10 names and which is not implemented — the mouse tap carries no moved events, a tracking area sees only our
own window, and what "departure" should mean once the pointer is back over the app is a design question the hover work
has to answer — and the fact that **nothing has watched it appear**: `AppAssembly` now builds `BarController` over a
real `BarWindow` (architecture §13.1), so the seam is no longer a fake everywhere, but a bundle that builds and signs
is not a bar anyone has used.

The analysis stage is built — the other half of M1 week 3, and the whole of `PappuAnalysis`. `ContentAnalyzer`
answers FLT-2 with four detectors in a fixed order, each allowed to claim only text no earlier one took:
`NSDataDetector` for the addresses and emails the system already has the grammar for, then a scheme from the
bundled list, then a path that is actually on this Mac, then a scheme-less host whose last label is a real
top-level domain. Paths go before hosts because `~/notes.md` ends in a real TLD and is not a website. Both
documents are data in `Resources/` — `url-schemes.json` and `top-level-domains.txt`, the latter regenerated by
`Scripts/update-tld-list.sh` — and neither is ever fetched at runtime: the stage has 20 ms and the app makes no
network call to decide what is on the user's screen. `AnalysisLimits` is the ceiling on all of it, characters,
detections, disk checks and a budget for the disk checks, because a stat against a stalled network mount blocks
for as long as the mount lets it; the numbers are **provisional** against PRD §11.1, like the rest.

`ContextProbe` is FLT-3, read in one pass on `AXActor` against a `ReadPermit`, and it reads no attribute that can
hold the selection. Two parts of it are worth naming. `EditMenuProbe` matches Cut, Copy and Paste by key
equivalent and never by title — an app may call the item anything at all, in any language, but it is not free to
change that Cut is ⌘X — and locates the three elements once per pid, so an attempt afterwards costs three
`AXEnabled` reads rather than a menu-bar walk; an element gone stale is re-located once and once only. And FLT-6
is settled here: the menu is asked but not believed over the element, because Chromium leaves Cut and Paste
enabled on read-only web content, so read-only text offers neither whatever the menu says, with the menu's own
answer kept for the inspector. `BrowserMetadata` is the AX tier of FLT-3's web half — `AXWebArea` answers `AXURL`
and usually `AXTitle`, at no consent cost — and it only walks once something has already said this is web
content, so a native app never pays for a tree walk. The second tier and the per-browser capability table are M4.

Its eighty-eight tests drive `FakeAXWorld` and a fake file probe, so what is *not* covered is the three real
implementations: `SystemAppNames` wants a running application, `SystemFileProbe` wants a disk, and the AX side has
never met a real Chromium or Electron tree — which is spike 4's territory, and the same grant session.

The invocation runtime is built — M1 week 5's safety substrate, ahead of the actions that will spend it
(`PappuRuntime`, safety spec §S3). `DestinationSnapshot` is RUN-1: where the text came from, frozen at the moment
the user asked, and immutable by construction — everything that happens afterwards is recorded *beside* it and
never written into it. It holds a SHA-256 and a length rather than the selection, and a `DestinationHandle` rather
than an element, because an `AXUIElement` may never leave `AXActor`; the probe holds the elements and drops them
when the invocation ends, so a finished invocation has no grip on a window that has since closed.
`DestinationVerifier` is RUN-2's three tiers, and `MutationPermit.init` is internal to the module with the
verifier as its only caller, so a mutation that skipped verification does not compile. `InvocationManager` is the
lifecycle: it takes the listen-only key-tap lease for the whole life of any run that may mutate text, rewrites a
focus change into our own surface so the bar is not mistaken for a new destination (RUN-1c), and ends everything
on cancel, pause or revocation (RUN-3).

Two decisions in it are deviations worth recording. **An Accessibility read whose app has gone quiet falls through
to the quiescence tier.** The spec's table reads as though the middle tier belongs to strategies 4–5, but an app
that will not answer `AXFocusedUIElement` at execution time leaves exactly the evidence a strategy-5 read leaves,
and refusing it would mean refusing paste in the apps that need it most. **A contradiction never falls through.**
An app that answers with a *different* range or a different digest has not gone quiet, it has told us the
selection moved, and that is a refusal at every tier — a hole found while writing the tests, and closed. The other
thing to know is that cancellation is synchronous by construction: `cancel` flips the state before its first
`await`, and `verifyDestination` re-checks after its own, so a permit cannot outlive its invocation by one
Accessibility round trip.

Its forty-seven tests run in three suites over fakes for all five seams — the probe, the input epochs, the work
being cancelled, the sleep the grace period measures, and the frontmost app. The last suite is RUN-5's eight
scenarios as unit tests: Notes → Terminal, editing the source, changing the selection, closing the window, secure
input arriving mid-action, a cancel just before completion, a newer selection racing an older detection, and the
quiescence paste with and without an intervening keystroke. Each asserts the same three things at the end —
nothing still running, no lease still held, no element still held. Two of them are also on the M1 manual
checklist (`docs/checklists/m1-manual.md`), because a real Notes window and a real Terminal are the only way
to know the fakes are telling the truth. `InvocationTiming` — the 3 s quiescence window and the 2 s
cancellation grace — is **provisional** and waits on spike 6's `live` run.

The write path is built too, which is the half of `ClipboardBroker` that was missing and the last of the runtime
substrate. `TextMutator` is the other end of the same rope, and it is short: take a `MutationPermit`, ask the
manager whether the run is still live, hand the text to `ClipboardBroker.paste`, mark the record as mutated if it went.
RUN-2a, RUN-2c and RUN-2d needed no code of their own, which is the whole design — a blocked verification mints
no permit, `replaceSelection` cannot be called without one, and it is the only thing in the program that puts an
action's result on the user's clipboard. There is no "the paste failed, so copy it for them instead" path, and
its absence **is** RUN-2d. The liveness check in front of the transaction is not the same as the one the
verification already made: a permit is minted before the clipboard work and spent after it, and Escape does not
wait its turn.

It posts a ⌘V rather than writing `AXSelectedText`, and that is RUN-4's doing. Setting the attribute would be one
Accessibility call with no clipboard involved at all, but most apps do not register a programmatic write with
their undo manager, so the user's ⌘Z afterwards does nothing — or undoes the edit *before* ours, which is worse
than nothing. The cost of the keystroke is the clipboard round trip, and the broker's write transaction is the
read transaction backwards and sharper: snapshot the user's clipboard or refuse outright, clear and write the
result marked transient and concealed, post the keystroke, hold, put their clipboard back. No snapshot means no
transaction, because a clipboard that cannot be read faithfully cannot be put back. A stranger's write during the
hold wins and is left alone, exactly as on the read path. A ⌘V that could not be posted takes the text straight
back down rather than serving out the hold, because holding the user's clipboard for a paste nobody was ever
asked for is the one shape this must never take.

`ClipboardTiming.holdMs` is 120 ms and **provisional**, and it is the one number in the whole broker that nothing
can measure for us: a paste moves no change count and leaves no type behind, so the hold is a two-sided guess —
too short and the app pastes the user's own clipboard over their selection, too long and their clipboard is
missing for no reason. Row 11 of `docs/checklists/m1-manual.md` is what turns it into a measurement, and rows 1–8
of the same page are the only place RUN-4's actual claim can be checked, because only another app's undo manager
knows whether one action was one ⌘Z. Seventeen tests: nine over the mutator with the real broker underneath it,
eight over the transaction alone.

The action layer is built: the part of week 5 that decides *what the bar shows*. It is three pieces and one
document. `ExtensionManifest` and `ActionManifest` (`PappuCore`) are §8.3's M1 subset — what the built-ins need
and what the resolver reads, with the rest of the keys absent rather than present and ignored, because a key the
model carries but nothing honours is indistinguishable, from an author's side, from one that works.
`ActionMatching` is §8.5 as a pure function over `MatchingFacts`, so the pipeline runs with no AX tree and no
running app, which is what the registry's conformance CI will need. `ActionCatalog` is the action list as a
value: a plain ordered array, uncapped, which is the only way ALM-1 is ever kept. `ActionResolver`
(`PappuRuntime`, FLT-1) is the impure part, and it is in that module because it is the first one allowed to hold
an `AnalyzedSelection`, a `SelectionContext` and the extension store at once — `PappuAnalysis` may not know the
store, and `PappuSelection` and `PappuAnalysis` may not know each other. It returns both halves of the answer:
the actions to show, in catalog order, and why each of the others is not there, which is the only moment DIA-2's
"why is Cut not here" has an answer to keep.

The five P0 built-ins are **files**, in `Resources/BuiltinExtensions/`, each a real manifest whose `executor`
names the reserved `builtin` form that `validate(origin:)` accepts only from `.appBundle`. That is PRD principle
5 made structural rather than promised: they are loaded by the same reader, keyed the same way, ordered in the
same list and drawn by the same bar as anything a user installs. Two of PRD §7.4's "shown when" clauses cannot
be said in §8.5's vocabulary — Paste needs text on the *clipboard*, Search has a maximum length — and rather
than invent two requirement spellings in a vocabulary that is a public API this project does not own, they are
`BuiltinConditions`, applied after the shared pipeline. The third, "Search unless the selection is only a URL",
needed nothing new: `[text, !isurl]`. `Resources/search-engines.json` holds PRD §7.4's twelve presets, with the
term percent-encoded against the unreserved set so that a selection containing `&` cannot add its own query
parameters.

The rest of week 5 is built, and with it the thing that had been missing from the start: an app. `BuiltinRunner`
(`PappuRuntime`) stands behind the reserved executor, and each of the five built-ins is one of three shapes — the
app's own ⌘X or ⌘V through `SelectionEditor`, a held clipboard write through `TextMutator`, or a kept write that needs
no permit at all. Copy is the last of those and the one real departure from PRD §7.4 in M1: a synthetic ⌘C is
synthetic input, so it would need a `MutationPermit`; the verifier mints one only for an editable destination; and
Copy is offered wherever there is text — a web page, a PDF, a log. A permit-shaped Copy would therefore be permanently
broken in exactly the places people copy from most, while writing the text PappuClip already read produces the same
result in a build with no rich-text model. The ⌘C-for-flavours path arrives with M3's model, together with the ⇧
modifier that is the only way to tell the two results apart.

`PappuApp` is the new module and the top of the tree, and it exists because `PappuSurfaces` asks two questions — what
should this bar hold, what should a press do — that only `PappuRuntime` can answer, and neither module may name the
other. `SelectionBridge` is that answer and `AppAssembly` is everything else: one `init` in dependency order, every
seam in the architecture document a constructor argument, with `App/PappuClip/Main.swift` sixty-odd lines of
`NSApplicationDelegate` over it. The menu bar item, the Settings window — General and Actions, per-app rules as a
sheet — and the onboarding window are all there. ONB-1's "detect the grant live" is the one behaviour among them that
is neither a stored setting nor a pure rule, and it is the reason `AccessibilityMonitor` re-reads rather than
believes: the `com.apple.accessibility.api` notification says "look again", never "you are trusted now", and the
window asking for the permission closes itself when the answer changes.

`Scripts/build.sh PappuClip` produces a signed `PappuClip.app`, the package's tests pass and
`Scripts/lint-layering.sh` is green. **And that is where it stops.** Nobody has launched it. The grant it needs is the
grant this runbook is about; rows 16–22 of `docs/checklists/m1-manual.md` are the new ones, the grant arriving and
going away and coming back stale while the app runs, and they join every other row of that page and every run above in
wanting a Mac with a person at it. An assembly that compiles is not one of the answers they are asking for.
