# M0 runbook — what is left, and who has to do it

State on 2026-09-20. One Mac (Mac16,10, macOS 26.4.1). SpikeLab has **no** Accessibility, Input Monitoring or
post-event access there, and granting them is the owner's call, so everything that could be measured without them
has been, and the rest is listed here as commands to run.

## Where the six spikes stand

| Spike | Code | Runs | Report | Blocked on |
|---|---|---|---|---|
| 2 · taps and permissions | done | 4, nothing granted | [`spike-2-taps.md`](spike-2-taps.md), running | Accessibility grant; a watched run |
| 1 · panel above fullscreen, focus | done | 1, nothing granted, unwatched | none | Accessibility grant; eyes on the screen |
| 3 · selection strategies per app | done | none | none | Accessibility grant; one run per app |
| 4 · switching on the AX tree | done | none | none | Accessibility grant; one run per Chromium or Electron app |
| 6 · clipboard and quiescence | done | 3, nothing granted | [`spike-6-clipboard.md`](spike-6-clipboard.md), running | Accessibility and post-event access for the `epoch` and `live` parts |
| 5 · JavaScript helper | done | 5 | [`spike-5-js-helper.md`](spike-5-js-helper.md), answered with a design change | nothing |

Spikes 3 and 4 have no result file. With nothing granted both stop at their first line ("Accessibility is not
granted"), which is all that has been exercised of them; expect to find bugs on the first real run, as spike 6's
first runs did.

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
   `Scripts/setup-dev-signing.sh`), and whether it survives a rebuild is itself one of spike 2's questions, so note
   if macOS asks again after a build.
2. System Settings → Privacy & Security → **Accessibility** → switch SpikeLab on. Do **not** add Input Monitoring
   yet: spike 2 wants to see what works with one grant.
3. Always start runs with `Scripts/run-spike.sh`, never the binary from a shell: a shell-started run describes the
   terminal's permissions (see `Tests/results/README.md`).
4. Put what was true into `--state "…"` and, afterwards, anything you saw that the log cannot know (prompts, panels,
   stutters) into the report. The result files hold counts, lengths and times, and nothing of what was on your
   clipboard or in your selection.

## The runs, in the plan's order

**Spike 2** — see the numbered list at the end of [`spike-2-taps.md`](spike-2-taps.md). About ten minutes. Its first
step also decides whether the active mouse tap is available with Accessibility alone, which every later spike
leans on.

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
- The first `DetectionPolicies.json` and the final Tier A gating list (spike 3).
- Revised stage budgets, hard cutoff and quiescence window (spikes 3 and 6).
- Spike 5's changes are written into `docs/architecture.md` (§10.1, §10.2, §10.6, §10.7), the two proposals among
  them marked as proposals. Spike 6's are listed at the end of §5 as found and not yet designed in; the state
  machine itself is still the one from before the spike and has to be redrawn once the decision below is made.
  PRD §11.1 does not yet carry spike 5's proposed memory budget (60 MB warm, 250 MB watchdog limit).
- One decision that does not need more data: what to do about a foreign write that lands before the app's copy
  (spike 6, "the first-writer hole"). It should be settled before the broker is built in M1 week 3.
- The licence decision, the §19 items, and the M3–M5 re-estimate.
- macOS 15 and the current beta: no run of any spike has been made on either.
