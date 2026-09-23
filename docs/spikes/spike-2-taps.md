# Spike 2 — Event taps and permissions

| | |
|---|---|
| **Question** | "Event-tap type versus permission prompts, including installing the key-down tap only while it is needed (ACT-19)." (PRD §12, item 2) |
| **Status** | running. Two states have been run: nothing granted, and Accessibility alone with nobody at the mouse. The second answers the one-grant question, ACT-19's cost, recovery from a disabled tap and the rebuild question. The prompts, the stall and real mouse events still need a watched run |
| **Result files** | `Tests/results/spike-2-taps/20260920T124910-macOS26.4.1-arm64.json` — nothing granted; first launch with the stable certificate; option `listen-only`<br>`Tests/results/spike-2-taps/20260920T125017-macOS26.4.1-arm64.json` — nothing granted; rebuilt since the previous run; options `listen-only,mouse-watch`<br>`Tests/results/spike-2-taps/20260920T132220-macOS26.4.1-arm64.json` — meant as "Accessibility only", but SpikeLab was listed under Accessibility with its switch off, so it is a third run with nothing granted<br>`Tests/results/spike-2-taps/20260920T143435-macOS26.4.1-arm64.json` — nothing granted; rebuilt after the change to the tap callback's context made for spike 6 (see "What the log cannot know")<br>`Tests/results/spike-2-taps/20260920T183044-macOS26.4.1-arm64.json` — Accessibility switched on by the owner; options none (active taps only)<br>`Tests/results/spike-2-taps/20260920T183100-macOS26.4.1-arm64.json` — the same, sixteen seconds later, after `Scripts/build.sh` had produced a new binary |
| **Machines** | One: Mac16,10 (Apple silicon), macOS 26.4.1 (25E253). **Missing: macOS 15 and the current beta** |

All six runs were headless (`Scripts/run-spike.sh`), started through `open` so that SpikeLab and not the terminal
is the responsible process, and signed with the stable "PappuClip Development" certificate. Nobody was watching
the screen for any of them, so nothing in them depends on a click or a prompt having been seen. The last two were
run with every option off, so that they asked for no listen-only tap: whether that raises a prompt is a question
for a run with eyes on it.

## Answer

Without any grant, macOS 26.4.1 refuses an active tap of either kind and a listen-only key-down tap, and **creates
a listen-only mouse tap**, which the design expected to need Input Monitoring. Whether that tap is sent anything is
not known: nobody clicked during the six seconds it listened.

With Accessibility switched on and nothing else touched, both active taps are created, so **the design's one grant
is enough for the mouse tap and the on-demand key tap**. `CGPreflightListenEventAccess` and
`CGPreflightPostEventAccess` both answer true in that state; SpikeLab never asked for either. Installing the key
tap costs p95 0.04 to 0.06 ms against ACT-19's 10 ms ceiling, a key posted straight after the install reaches it
20 times of 20, none of 100 posted keys was lost, and a tap that was switched off reports it, sees nothing while
off and sees events again once switched back on. **The grant survived a rebuild**: a different code hash, the same
certificate, still trusted, no prompt needed.

Still open: what macOS shows when a listen-only tap is asked for, the 2 s stall and its `tapDisabledByTimeout`
notice, whether real mouse events reach the taps (every event so far was one SpikeLab posted), and the state with
Input Monitoring granted as well.

## What the design assumed, and what we found

| Assumption | Where it comes from | Finding key | Outcome | Evidence |
|---|---|---|---|---|
| An active tap needs Accessibility, and nothing more | PRD §12, architecture §4.1 | `tap.active.mouse.created`, `tap.active.keyDown.created` | confirmed | Not created with nothing granted, four runs of four. Created with Accessibility alone, two runs of two |
| A listen-only tap needs Input Monitoring | PRD §12 | `tap.listenOnly.keyDown.created` | confirmed, for the refusal only | Key-down: not created |
| | | `tap.listenOnly.mouse.created` | **refuted** | Mouse (down, up, dragged, right, other, scroll): created with nothing granted, four runs of four |
| …and being created means being sent events | — | `tap.listenOnly.mouse.receivesEvents` | inconclusive | 0 events in 6 s, and nobody clicked, so this says nothing either way |
| A key-down tap can be installed per surface cheaply | ACT-19 | `keyTap.lease.installIsCheap` | confirmed | 50 install and remove cycles per run; install p95 0.040 and 0.062 ms, max 0.077 ms; ceiling 10 ms |
| …and sees a key pressed right after it is installed | ACT-19 | `keyTap.lease.seesKeyPressedRightAfterInstall` | confirmed | 20 of 20 in both runs. One key took 21.6 ms to arrive in the run straight after the rebuild (see Measurements) |
| The tap loses no key events | architecture §4.1 | `keyTap.delivery.lost` | confirmed, for posted events | 0 of 100 lost, both runs |
| A disabled tap can be detected and switched back on | architecture §4.1 | `tap.reenable` | confirmed | `reportsDisabled=true seenWhileDisabled=false seenAfterReenable=true`, both runs |
| …including one macOS disabled for being slow | architecture §4.1, ACT-15 | `tap.timeout.*` | not run | `--enable stall` |
| The grant survives a rebuild under a stable certificate | PRD §12 | `tcc.grantSurvivesRebuild` | confirmed | Code hash `d63f1fcf…` trusted, rebuilt to `de0b601d…`, still trusted, same certificate. Once, on one Mac |

One more observation, from spike 6's files and not this spike's: a listen-only tap whose mask mixes mouse-down,
**key-down** and scroll was created with nothing granted (`epoch.tap = listenOnly` in
`Tests/results/spike-6-clipboard/`). A key-down-only listen-only tap is refused, so the refusal seems to depend on
the whole mask and not on key-down being in it. Whether such a tap is ever sent a key-down was not seen: the tap
counted no events in any of those windows. Nobody was typing, but a test job of another project was running on the Mac
at the time, and one of its scripts presses keys (see spike 6's report), so "no keys were pressed" is not
established either. If such a tap is sent key-downs, that is a privacy-relevant finding about macOS and a reason for PappuClip
never to put key-down into a mask it does not need; if it is not, the tap is silently partial, which the product
must not mistake for "no keys were pressed".

## Measurements

`tap.create`, in milliseconds, one sample per run (so there is no distribution to give), four runs:

| Tap | Created | Run 1 | Run 2 | Run 3 | Run 4 |
|---|---|---|---|---|---|
| active, mouse | no | 10.6 | 19.9 | 10.0 | 2.3 |
| active, key-down | no | 0.29 | 0.27 | 0.31 | 0.10 |
| listen-only, mouse | yes | 16.8 | 5.1 | 0.70 | 0.10 |
| listen-only, key-down | no | 1.3 | 0.04 | 0.02 | 0.03 |

The first tap asked for in a process cost between 2 and 20 ms, refused or not; later refusals are well under a
millisecond. What the first one pays for was not looked into. It matters for ACT-19's 10 ms install ceiling only if
the key tap were the first tap in the process, which it is not: the mouse tap is up whenever PappuClip is not paused
(architecture §4.1).
With Accessibility, the first tap (active, mouse) was created in 1.9 and 3.0 ms and the active key-down tap in
0.04 and 0.07 ms.

The on-demand key tap, in milliseconds. Run 5 is the build that had been started several times already, run 6 the
first start of a new binary:

| Series | n | Run 5 p50 / p95 / max | Run 6 p50 / p95 / max |
|---|---|---|---|
| `keyTap.install` | 50 | 0.028 / 0.040 / 0.042 | 0.032 / 0.062 / 0.077 |
| `keyTap.remove` | 50 | 0.025 / 0.037 / 0.051 | 0.029 / 0.060 / 6.3 |
| `keyTap.firstEventAfterInstall` | 20 | 0.033 / 0.043 / 0.071 | 0.073 / 0.60 / 21.6 |
| `keyTap.eventDelivery` | 100 | 0.030 / 0.037 / 0.051 | 0.052 / 0.127 / 13.0 |

The install is three orders of magnitude under its ceiling in both. Run 6's tails are single samples: one remove of
6 ms, one first event of 21.6 ms, delivery up to 13 ms. Nothing was lost, only late. Whether that is the first
start of a new binary or the machine being busy cannot be told from two runs. It matters to the design as a
reminder that a key can reach the lease tens of milliseconds after it was posted; the lease must not conclude "no
key was pressed" from a short silence.

## What the log cannot know

- No run was watched, so whether macOS showed a prompt when the listen-only taps were asked for is **not known**.
  The spike's own instructions ask the operator to write prompts down; that has not happened yet.
- "Accessibility only" in the last two files is what the owner of the Mac said they had switched on. The files
  show `inputMonitoring=true postEvent=true` next to it. Those are the answers of the two preflight calls, not the
  state of the Input Monitoring list in System Settings, which nobody looked at. If SpikeLab is absent from that
  list, the preflight calls follow the Accessibility grant on this macOS, and the product cannot use them to tell
  the two grants apart.
- Every key event in the last two runs was an F13 that SpikeLab posted and its own tap swallowed. No event from a
  real keyboard or mouse has reached an active tap in any run yet.
- The third file's state was typed in as "Accessibility only" in intent. The permission snapshot in the file
  (`accessibility=false`) is what is true; the note in `tccState` says why.
- A run of spike 6 crashed inside the tap callback that both spikes share (`EventTap.swift`). The cause is not
  settled; see spike 6's report. None of this spike's runs crashed: three before the change made there, one after.
  None of them saw an input event or a tap-disabled notice either, so they say little about it.
- The fourth run (14:34 UTC) was made while a test job of another project was running on the same Mac, starting apps
  that come to the front and, in one of its scripts, pressing keys. The first three were made before
  it started (13:47 UTC). The refusals and the one creation are the same in all four.

## Consequences

- **Design changes:** none. Architecture §4.1 stands as drawn: an active mouse tap and a key-down tap leased per
  surface, on the one Accessibility grant. `EventTapService` and `KeyTapLease` (M1 week 1) can be built on that. If the permission-less listen-only mouse tap turns out to be sent events, the
  pre-permission onboarding could show a live "we can see your clicks, we cannot see your keys" state, and the
  degraded mode without Accessibility would have more to work with than the design assumes. Not to be built on
  until a watched run shows events arriving.
- **Architecture §19 items this closes:** none.
- **Budget changes (PRD §11.1):** none.
- **Paths disabled rather than weakened:** none.
- **Licence:** no GPL-3.0 code was read or reused.

## Not covered

All of this needs the owner of the Mac: the grants are theirs to give, and the prompts need eyes.

1. **Accessibility only, watched.** The grant is in place. `Scripts/run-spike.sh spike-2-taps --state
   "Accessibility only"`, clicking and scrolling for the six seconds after the taps are created (the log is only
   printed at the end, so start clicking about a second after launch, or use the SpikeLab window, which logs
   live). Decides: whether real mouse events reach the taps; whether asking for a listen-only tap raises the Input
   Monitoring prompt. Look at the Input Monitoring list before and after, and put what it shows into `--state`.
2. **The same with `--enable listen-only,mouse-watch,stall`**, hands off the keyboard: the 2 s stall, the
   `tapDisabledByTimeout` notice, and recovery.
3. ~~Rebuild and run again~~ Done once (runs 5 and 6). Worth repeating after a reboot and after an Xcode
   update, which are the other two things said to cost a development build its grant.
4. **Accessibility and Input Monitoring**, the same command with that state named.
5. **Nothing granted, watched**, clicking during the six seconds: settles `tap.listenOnly.mouse.receivesEvents`.
   Remove SpikeLab from both lists first (`tccutil reset All app.pappuclip.SpikeLab`).
6. macOS 15 and the current beta.
