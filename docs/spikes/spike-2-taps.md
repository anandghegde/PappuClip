# Spike 2 — Event taps and permissions

| | |
|---|---|
| **Question** | "Event-tap type versus permission prompts, including installing the key-down tap only while it is needed (ACT-19)." (PRD §12, item 2) |
| **Status** | running. Only the state with nothing granted has been run. It answers which taps exist without a grant and nothing else |
| **Result files** | `Tests/results/spike-2-taps/20260920T124910-macOS26.4.1-arm64.json` — nothing granted; first launch with the stable certificate; option `listen-only`<br>`Tests/results/spike-2-taps/20260920T125017-macOS26.4.1-arm64.json` — nothing granted; rebuilt since the previous run; options `listen-only,mouse-watch`<br>`Tests/results/spike-2-taps/20260920T132220-macOS26.4.1-arm64.json` — meant as "Accessibility only", but SpikeLab was listed under Accessibility with its switch off, so it is a third run with nothing granted<br>`Tests/results/spike-2-taps/20260920T143435-macOS26.4.1-arm64.json` — nothing granted; rebuilt after the change to the tap callback's context made for spike 6 (see "What the log cannot know") |
| **Machines** | One: Mac16,10 (Apple silicon), macOS 26.4.1 (25E253). **Missing: macOS 15 and the current beta** |

All four runs were headless (`Scripts/run-spike.sh`), started through `open` so that SpikeLab and not the terminal
is the responsible process, and signed with the stable "PappuClip Development" certificate. Nobody was at the
machine, so nothing in them depends on a click or a prompt having been seen.

## Answer

Without any grant, macOS 26.4.1 refuses an active tap of either kind and a listen-only key-down tap, and **creates
a listen-only mouse tap**, which the design expected to need Input Monitoring. Whether that tap is sent anything is
not known: nobody clicked during the six seconds it listened. Everything the spike exists to decide, which is one
prompt or two, the cost of the on-demand key tap, recovery from a disabled tap, and whether the grant survives a
rebuild, needs the Accessibility grant and has not been run.

## What the design assumed, and what we found

| Assumption | Where it comes from | Finding key | Outcome | Evidence |
|---|---|---|---|---|
| An active tap needs Accessibility | PRD §12, architecture §4.1 | `tap.active.mouse.created`, `tap.active.keyDown.created` | confirmed, for the refusal only | Not created with nothing granted, four runs of four. That it *is* created with Accessibility alone is the half that matters and is not yet run |
| A listen-only tap needs Input Monitoring | PRD §12 | `tap.listenOnly.keyDown.created` | confirmed, for the refusal only | Key-down: not created |
| | | `tap.listenOnly.mouse.created` | **refuted** | Mouse (down, up, dragged, right, other, scroll): created with nothing granted, four runs of four |
| …and being created means being sent events | — | `tap.listenOnly.mouse.receivesEvents` | inconclusive | 0 events in 6 s, and nobody clicked, so this says nothing either way |
| A key-down tap can be installed per surface cheaply | ACT-19 | `keyTap.lease` | inconclusive | No active key-down tap could be created |
| A disabled tap can be detected and switched back on | architecture §4.1 | `tap.timeout.*`, `tap.reenable` | not run | Needs an active tap; `--enable stall` |
| The grant survives a rebuild under a stable certificate | PRD §12 | `tcc.grantSurvivesRebuild` | inconclusive | The build changed between runs (the code hash differs from file to file), but there was no grant to lose |

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
The install cost that counts is `keyTap.lease.installIsCheap`, 50 cycles, not yet measured.

## What the log cannot know

- No run was watched, so whether macOS showed a prompt when the listen-only taps were asked for is **not known**.
  The spike's own instructions ask the operator to write prompts down; that has not happened yet.
- The third file's state was typed in as "Accessibility only" in intent. The permission snapshot in the file
  (`accessibility=false`) is what is true; the note in `tccState` says why.
- A run of spike 6 crashed inside the tap callback that both spikes share (`EventTap.swift`). The cause is not
  settled; see spike 6's report. None of this spike's runs crashed: three before the change made there, one after.
  None of them saw an input event or a tap-disabled notice either, so they say little about it.
- The fourth run (14:34 UTC) was made while a test job of another project was running on the same Mac, starting apps
  that come to the front and, in one of its scripts, pressing keys. The first three were made before
  it started (13:47 UTC). The refusals and the one creation are the same in all four.

## Consequences

- **Design changes:** none yet. If the permission-less listen-only mouse tap turns out to be sent events, the
  pre-permission onboarding could show a live "we can see your clicks, we cannot see your keys" state, and the
  degraded mode without Accessibility would have more to work with than the design assumes. Not to be built on
  until a watched run shows events arriving.
- **Architecture §19 items this closes:** none.
- **Budget changes (PRD §11.1):** none.
- **Paths disabled rather than weakened:** none.
- **Licence:** no GPL-3.0 code was read or reused.

## Not covered

All of this needs the owner of the Mac: the grants are theirs to give, and the prompts need eyes.

1. **Accessibility only.** System Settings → Privacy & Security → Accessibility → switch SpikeLab on (it was
   listed, switched off, at the time of the third run). Then `Scripts/run-spike.sh spike-2-taps --state "Accessibility only"`, clicking and
   scrolling when the log asks. Decides: active taps created with one grant; `keyTap.lease.*` (ACT-19);
   `keyTap.delivery`; `tap.reenable`; whether asking for a listen-only tap raises the Input Monitoring prompt.
2. **The same with `--enable listen-only,mouse-watch,stall`**, hands off the keyboard: the 2 s stall, the
   `tapDisabledByTimeout` notice, and recovery.
3. **Rebuild and run again** with nothing else changed (`Scripts/build.sh`, then step 1's command):
   `tcc.grantSurvivesRebuild`.
4. **Accessibility and Input Monitoring**, the same command with that state named.
5. **Nothing granted, watched**, clicking during the six seconds: settles `tap.listenOnly.mouse.receivesEvents`.
   Remove SpikeLab from both lists first (`tccutil reset All app.pappuclip.SpikeLab`).
6. macOS 15 and the current beta.
