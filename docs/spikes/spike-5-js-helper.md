# Spike 5 — JavaScript in a sandboxed helper

| | |
|---|---|
| **Question** | "JavaScriptCore in a sandboxed XPC helper: startup time, warm-helper memory, pre-warming on mouse-down, host-proxied network, and interpreter-only performance without the JIT entitlement." (PRD §12, item 5) |
| **Status** | answered with a design change |
| **Result files** | `Tests/results/spike-5-js-helper/20260920T135117-macOS26.4.1-arm64.json` — first run after a build, all options on<br>`Tests/results/spike-5-js-helper/20260920T135249-macOS26.4.1-arm64.json` — same build, second run<br>`Tests/results/spike-5-js-helper/20260920T135421-macOS26.4.1-arm64.json` — same build, third run; the figures quoted below are from this file unless another is named<br>`Tests/results/spike-5-js-helper/20260920T135745-macOS26.4.1-arm64.json` — rebuilt with the selection-size series added (`warm.populate.bySize`); otherwise agrees with the other three<br>`Tests/results/spike-5-js-helper/20260920T140000-macOS26.4.1-arm64.json` — rebuilt with the in-line reply comparison added (`helper.inLineRepliesSerialiseTheHelper`); otherwise agrees |
| **Machines** | One: Mac16,10 (Apple silicon), macOS 26.4.1 (25E253). **Missing: macOS 15, the current beta, and any Intel Mac.** Interpreter speed on Intel is the figure most likely to differ. |

The spike needs no permission, so these are real runs and not dry ones. The helper is `App/SpikeJSHost`: an XPC
service signed with `com.apple.security.app-sandbox` and nothing else, embedded in SpikeLab. The fixtures
(`App/SpikeFixtures`) are synthetic; see "Not covered".

## Answer

A warm helper is far inside the budget: a population function costs about 0.1 ms round trip, three of them 0.4 ms
in sequence, and the transport's own share is about 0.04 ms, against a stage of 30 ms. `XPCSession` with `Codable`
messages carries everything the design asks of it, including a blocking call from JavaScript back into the app
while the app is waiting on the helper, so the `NSXPCConnection` fallback is not needed. The sandbox gives the
helper no network, no files and no JIT memory, and the interpreter is 8 to 13 times slower than the JIT on calls
and regular expressions, which does not matter for population and will matter for heavy actions.

Two things the design did not know. **launchd holds back a helper that died in its first ten seconds**, for the
rest of those ten seconds, which bounds how fast crash recovery can be (architecture §10.7). And the plain `Codable`
message handler answers in line, which put a 549 ms wait in front of a 0.1 ms populate while another VM was busy:
"one thread per VM" only buys independence if the helper takes messages as `XPCReceivedMessage` and hands each
reply off to the VM's queue.

## What the design assumed, and what we found

| Assumption | Where it comes from | Finding key | Outcome | Evidence |
|---|---|---|---|---|
| A warm helper populates within 15 ms a function | PRD §11.1, JS-16, JS-19 | `warm.populationFitsPerFunction` | confirmed | Slowest fixture (`regex`, eight patterns over a 330-byte selection): p95 0.2 ms |
| …and within 30 ms for all of them | PRD §11.1 | `warm.populationFitsTheStage.inSequence`, `.inParallel` | confirmed | Three functions: p95 0.4 ms in sequence, 0.2 ms in parallel. At that rate 50 dynamic extensions in sequence are about 7 ms |
| A large selection still fits | PRD §11.1 | `warm.largeSelectionFitsPerFunction` | **refuted** | 100 KB through the `regex` fixture: p95 15.9–16.2 ms against 15 ms, all three runs. All of it is inside the helper (15.8 ms); the transport carries 100 KB in under 0.1 ms. The other two fixtures: 0.3 ms |
| A cold helper cannot populate in time, so it is started at launch and population is skipped when it is cold | architecture §10.6 | `cold.helperMissesThePopulationStage` | confirmed | Cold start to a first populated reply: p95 48–53 ms against 30 ms |
| A cold helper at least fits the hard cutoff | PRD §11.1 | `cold.helperFitsTheHardCutoff` | confirmed | 48–53 ms against 700 ms, with nothing else in the attempt counted. Not true of the first start after an install or update: see Measurements |
| `XPCSession` with `Codable` is enough transport | architecture §10.2 | `transport.sessionOpens` | confirmed | Every session opened; no message failed to encode or decode |
| The blocking form of a host call works over the same session | architecture §10.2 | `transport.blockingHostCallWorks`, `transport.hostCallCost` | confirmed | App inside `sendSync` to the helper, helper inside `sendSync` to the app, the app's handler answered on another thread. Adds 0.03 ms at the median. This is the shape host-proxied `XMLHttpRequest` takes |
| One VM per extension on its own thread means a slow extension holds up nobody else | architecture §10.1 | `helper.aBusyVMHoldsUpNobodyElse` | confirmed, **with a condition** | One VM span for 600 ms; 200 rounds of populate on two other VMs and ping went through meanwhile at their usual cost (p95 0.14 ms, max 0.46 ms). The helper takes `XPCReceivedMessage` and uses `handoffReply(to:)` onto the VM's queue |
| *(the condition)* Answering from the message handler itself would do as well | — | `helper.inLineRepliesSerialiseTheHelper` | confirmed that it does not | The same probe with the busy VM answered in line, which is all the `Codable`-in, `Encodable`-out handler can do: a neighbour's populate took **549 ms** round trip, 0.1 ms of it in the helper. The session delivers messages one at a time, so per-VM threads alone do not give independence (fifth file) |
| The sandbox leaves the helper no files | SEC-1 | `sandbox.helperIsContained` | confirmed | Runs in a container; listing the user's real home directory fails |
| …and no network | SEC-1, SEC-6 | `sandbox.noNetwork` | confirmed | `connect()` to the loopback: `EPERM`. Not even localhost |
| Without `allow-jit` JavaScriptCore interprets | architecture §10.1 | `sandbox.noJITMemory` | confirmed | `mmap(MAP_JIT)` with execute permission is refused; the benchmark in the helper matches `jsc --useJIT=false` |
| The app can watch the helper's CPU and memory from outside | architecture §10.7 | `watchdog.appCanSeeTheHelper`, `watchdog.seesARunaway` | confirmed | `proc_pid_rusage` on the sandboxed helper needs no entitlement. Its footprint agrees with the helper's own figure to 0.03 MB. `while (true) {}` showed as a full core within one 100 ms sample |
| Killing the helper fails what was in flight, and it comes back | architecture §10.7 | `watchdog.killFailsTheInvocation`, `watchdog.helperComesBack` | confirmed | The pending send failed 0.12 ms after `SIGKILL`. A new process with three extensions loaded again: 22–24 ms after the kill, **for a helper older than ten seconds** |
| *(not assumed)* A helper can always be restarted at once | — | `launchd.holdsBackAQuickRespawn` | **found** | A helper that exits or is killed less than ten seconds after it started is not started again until ten seconds have passed: 10 034–10 038 ms to the first reply, three runs out of three. launchd says so: `Service only ran for 0 seconds. Pushing respawn out by 10 seconds.` The helper killed at about five seconds of age, in a discarded run, came back after 5 059 ms |
| Dropping VMs gives the memory back | architecture §10.6 (memory-pressure teardown) | `memory.unloadGivesItBack` | confirmed | 31.9 MB with 50 VMs, 5.9 MB two seconds after dropping them all. Not all the way to the 2.3 MB it started at |

## Measurements

All in milliseconds unless marked, as p50 / p95 / max (n), from the third result file.

**Warm, against the population stage (30 ms, 15 ms a function)**

| Series | p50 | p95 | max | n |
|---|---|---|---|---|
| `warm.ping.roundTrip` (the mouse-down readiness check) | 0.047 | 0.063 | 0.094 | 200 |
| `warm.ping.inHelper` | 0.006 | 0.008 | 0.013 | 200 |
| `warm.populate.roundTrip` small | 0.070 | 0.102 | 0.550 | 100 |
| `warm.populate.roundTrip` regex | 0.154 | 0.220 | 0.854 | 100 |
| `warm.populate.roundTrip` large (250 KB of source) | 0.070 | 0.105 | 0.304 | 100 |
| `warm.populate.allInSequence` (3 functions) | 0.307 | 0.436 | 1.648 | 100 |
| `warm.populate.allInParallel` (3 functions) | 0.155 | 0.169 | 0.277 | 100 |
| `warm.populate.largeSelection.roundTrip` regex, 100 KB | 15.617 | 15.922 | 16.006 | 20 |
| `warm.evaluate.roundTrip` | 0.038 | 0.046 | 0.064 | 100 |
| `warm.evaluateWithHostCall.roundTrip` | 0.068 | 0.081 | 0.092 | 100 |

**Population against the size of the selection** (`warm.populate.bySize.roundTrip`, the `regex` fixture, n=20 each, fourth
file). The other two fixtures stay under 0.25 ms at every size.

| Selection | p50 | p95 | max |
|---|---|---|---|
| 330 bytes | 0.154 | 0.220 | 0.854 |
| 4 KB | 0.666 | 0.863 | 0.907 |
| 16 KB | 2.467 | 2.548 | 2.554 |
| 50 KB | 7.799 | 8.273 | 8.433 |
| 100 KB | 15.617 | 15.922 | 16.006 |

Linear, at about 0.16 ms a kilobyte for eight patterns.

The round trip less the time in the helper is the transport: 0.04 ms, the same for a 330-byte and a 100 KB selection
to within the noise. The worst single populate across all three runs was 2.2 ms.

**Loading an extension into a warm helper** (one sample each): small 2.2 ms (it is first, and pays for JavaScriptCore's
own first use), regex 0.7 ms, large 5.6 ms for 250 KB of source.

**Cold**

| Series | Figure |
|---|---|
| `cold.toFirstReply`, helper not run recently | 14.0 and 15.3 ms (one sample in each of runs 2 and 3) |
| `cold.toFirstReply`, half a second after the previous helper left | p50 33.1, p95 35.6, max 35.6 (n=5); the same in all three runs |
| `cold.toWarm` (three extensions loaded) | p50 44.2, p95 46.3 (n=5) |
| `cold.toFirstPopulation` | p50 46.0, p95 47.8 (n=5) |
| First start after a build (new code hash) | 384 ms in run 1 and 431 ms in run 4, the two runs that followed a build |
| First start ever on this Mac, which also creates the sandbox container | 1 261 ms, seen once, in a discarded run |
| `cold.afterAnEarlyExit` (launchd's hold-back) | 10 034, 10 037, 10 038 |

**Memory** (`phys_footprint`, MB)

| State | Footprint |
|---|---|
| Helper idle, no VM | 2.3 |
| 3 VMs loaded, each populated once | 11.3 |
| The same 3 VMs after 400 populations and the CPU benchmark | 17.4 |
| 50 VMs | 31.9 |
| Per additional VM (small, regex and large in rotation, each populated once) | 0.29–0.31 |
| Two seconds after dropping all 50 | 5.9 |

**Interpreter against JIT** (`App/SpikeFixtures/bench.js`, ms, same machine, median of three)

| Part | Helper | `jsc --useJIT=false` | `jsc` (JIT) | JIT is faster by |
|---|---|---|---|---|
| Function calls (`fib(32)`) | 105 | 107 | 8 | 13× |
| Regular expressions over 200 KB | 113 | 114 | 15 | 8× |
| String building, split, counting | 131 | 102 | 46 | 3× |
| `JSON` round trips | 38 | 28 | 28 | 1× |
| Sorting 300 000 numbers | 77 | 76 | 56 | 1.4× |

**Watchdog**: a runaway detected after 606 ms (the rule was "a full core for 500 ms", sampled every 100 ms); kill to
failed invocation 0.12 ms; kill to warm again 22.7 ms.

## What the log cannot know

- The first version of the spike told each cold helper to exit at once and measured the next start as 10 040 ms,
  seven rounds out of seven. That was launchd's hold-back and not a start. The evidence is launchd's own line in the
  unified log, quoted above, and spawn times exactly 10.55 s apart. That run's file was written to a scratch
  directory and is not in `Tests/results`; the spike now keeps every cold helper alive for eleven seconds before it
  lets it go, and measures the hold-back once on purpose.
- The build is Debug, so Xcode adds `com.apple.security.get-task-allow` to the helper's signature. It has no bearing
  on the sandbox, the network or the JIT, all of which were tested directly and not read off the entitlements.
- The machine was in ordinary use during the runs, with other apps open. Run 2 shows it: populate p99 rose to
  0.7–1.9 ms, still far inside the stage. Found later from the process list: a test job of another project, which
  starts and quits small apps over and over, began at 13:47 UTC and ran through all five runs (13:51 to 14:00).
- Nothing appeared on screen. No prompt, no Dock icon for the helper.

## Consequences

- **Design changes:**
  - *Architecture §10.2.* The helper's listener takes `XPCReceivedMessage` and replies with `handoffReply(to:)` from the
    VM's queue. The `Codable`-in, `Encodable`-out handler is used only for messages that never touch a VM (`ping`,
    `status`). Without this §10.1's per-VM threads do not give per-VM independence, and one slow population
    function would hold `ping` and every other extension behind it (measured: 549 ms). `XPCSession` stays; the `NSXPCConnection`
    fallback is dropped.
  - *Architecture §10.7.* Add launchd's ten-second rule. A helper the watchdog kills, or that crashes, before it is ten
    seconds old cannot be replaced until those ten seconds are up; after that, recovery is about 25 ms. So: (a) "cold,
    population skipped" (§10.6) is the state for that whole window and must not be treated as a second failure; (b) the
    three-crashes suspension window has to be counted in attempts to run the extension and not in wall-clock retries,
    because retries inside the window all fail the same way; (c) a crash loop during warm-up costs ten seconds a lap, so
    an extension that crashes the helper while loading is suspended on the first attributed crash at load, not the third.
  - *Architecture §10.6.* Population needs a bound on the size of the selection it is given, or has to rely on the
    deadline. One regular-expression extension over 100 KB costs 16 ms, which is one function's whole budget, and the
    cost is linear in the text. **Proposed:** population receives at most the first 16 KB of the selection's text, with
    the full length alongside, which holds a regex-heavy function to 2.5 ms on this machine (measured, p95). Invocation always gets
    the full text. Needs checking against the corpus in M2 for population functions that look at the end of the text.
  - *Architecture §10.6, pre-warming.* `ping` on mouse-down costs 0.05 ms and is kept. But a cold helper reaches a first
    populated reply in about 50 ms, which is shorter than any drag selection, so mouse-down could also *start and warm*
    a cold helper instead of only noticing that it is cold. That turns "skip population for this appearance" into a rare
    case (the launchd window, and the first start after an update). Worth adopting in M3; it costs nothing when the
    helper is warm.
  - *PRD §11.1, the warm helper's memory budget, which this spike was asked to set.* Measured: 2.3 MB for the process,
    about 3 MB for each of the first few VMs, 0.3 MB for each one after that, and a VM that has run real work grows (the
    three working VMs reached 17 MB). **Proposed budget: 60 MB `phys_footprint` with 50 dynamic extensions loaded**, about
    twice the 32 MB measured for 50 idle VMs, to leave room for heaps that have done work. The watchdog's memory limit for
    a runaway is a separate, higher figure: **proposed 250 MB**, to be revisited with real extensions in M3.
- **Architecture §19 items this closes:** none of the eight is about the helper. It settles the open choice in §10.2
  ("`NSXPCConnection` is the fallback if the spike finds a problem"): no problem found.
- **Budget changes (PRD §11.1):** none needed. Population spends well under a millisecond of its 30 ms with a warm
  helper. If another stage needs the time after spikes 1 and 3, population can give up 10 ms and still hold 50
  extensions; decide that once the read stage has been measured.
- **Paths disabled rather than weakened:** none.
- **Licence:** no GPL-3.0 code was used or wanted. The helper is JavaScriptCore and the XPC framework, both system.

## Not covered

- **Real extensions.** The three fixtures are synthetic, written for this spike in the shape of PopClip module
  extensions with a population function. The frozen corpus arrives in M2; M3's exit criterion ("warm helper within
  budget") repeats these measurements on it. The 16 KB proposal in particular needs the corpus.
- **The promise form of host calls** (XHR, `promptText`, `runShellScript`), timers and the VM run loop they need. Only the
  blocking form was tested. M3.
- **Real network through the host.** The app answered `httpRequest` with a canned reply; what was tested is the path,
  not `URLSession`, `networkHosts` or redirects. M3.
- **Heavy actions under the interpreter.** The benchmark says 8–13× on calls and regular expressions. Whether any corpus
  extension's *action* (not population) becomes unpleasant at that speed, for instance a Markdown converter on a long
  selection, is an M3 question; the answer is not the JIT entitlement, which is incompatible with the sandbox story, but
  knowing which extensions to warn about.
- **macOS 15, the current beta, Intel.** One machine.
- **Memory pressure.** Whether the system jetsams an idle helper, and how the app learns of it, was not provoked.
- **Release signing.** Runs used the self-signed development certificate and a Debug build. Notarised, with a Team ID, the
  first-start cost (384 ms after a build here) may differ; measure once at the M3 beta.
