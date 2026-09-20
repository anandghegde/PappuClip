# Spike 6 — Clipboard ownership and quiescence

| | |
|---|---|
| **Question** | "Clipboard transaction ownership and destination verification under delayed copy, concurrent user copy, source edits and app switches. Validate the quiescence tier (RUN-2): how reliably the event tap and frontmost-window checks detect intervening input, and what time window is safe." (PRD §12, item 6) |
| **Status** | running. The pasteboard half is answered with a design change. The quiescence half and everything per app wait for permissions that SpikeLab does not have on this Mac; see "Not covered" |
| **Result files** | `Tests/results/spike-6-clipboard/20260920T142739-macOS26.4.1-arm64.json` — no permissions, options `general,hung,epoch`<br>`Tests/results/spike-6-clipboard/20260920T142840-macOS26.4.1-arm64.json` — same build, second run<br>`Tests/results/spike-6-clipboard/20260920T142941-macOS26.4.1-arm64.json` — same build, third run<br>Figures below are given as the range over the three files. Every finding had the same outcome in all three |
| **Machines** | One: Mac16,10 (Apple silicon), macOS 26.4.1 (25E253). **Missing: macOS 15 and the current beta.** The pasteboard-privacy answer is the one most likely to differ on them |

Most of the spike needs no permission, because it plays both sides itself: SpikeLab is started a second time as
`SpikeLab --pasteboard-fixture <name>` and that process owns a named pasteboard, so every read goes through the
pasteboard server to another process, as it does with a real app. The fixture writes on command at a scripted
offset and reports its own times from the clock both processes share. A broker prototype (`Transaction` in
`ClipboardSpike.swift`, window 250 ms, drain 500 ms, 1 ms poll) follows the state machine of architecture §5 as
written, with nothing added, and is run against scripted copies and foreign writes. It has no `InputEpoch` and no
frontmost-window check, because nothing scripted produces input; what it measures is what the pasteboard alone can
and cannot tell the broker.

Nobody was at the keyboard for these runs. That matters in two places, both marked below. The machine was not idle
either: see the first item under "What the log cannot know".

## Answer

The change count moves when a writer **clears**, not when it has written, so "the count advanced" says a copy has
started and nothing about whether the text is there yet. The broker of §5 as written reads that moment as "no text
type" and abandons. With writers that do nothing between clearing and writing, a reader that looks at once finds no
string in 2% to 56% of rounds, depending on how the writer writes; at the broker's 1 ms poll it was 1 capture in 60.
The fix is a short wait for the text after the count moves, and it costs under half a millisecond at p95 for an app
that writes promptly.

Snapshot and restore are faithful for everything tried, up to 50 MB, and cheap: about 0.6 ms a megabyte. Two things
can still stop a snapshot. A lazy provider is served by the source app's main thread, and a provider that hangs
blocks the read for as long as it hangs, 12 s here, with no way to cancel. And a promise whose owner has died is
either forgotten or listed with nothing behind it, depending on whether the reader had looked before.

The pasteboard alone cannot close two holes. A copy that arrives after the drain window stays on the clipboard and
the earlier content is lost, for any finite drain. And a write from another program that lands before the app's copy
is taken for the selection: count delta 1, text type present, inside the window. `InputEpoch` is the design's
answer to the second and it cannot see a write that no input caused. Both were 10 rounds in 10, every run.

On this Mac macOS does not hold up a programmatic read of the general pasteboard. The quiescence tier is untested.

## What the design assumed, and what we found

| Assumption | Where it comes from | Finding key | Outcome | Evidence |
|---|---|---|---|---|
| "Count advanced" and "holds a text type" can be checked together | architecture §5, attribution | `count.movesWhenClearedNotWhenWritten` | confirmed, so **the assumption does not hold** | Moves the count by 1: `clearContents`, `declareTypes`, `prepareForNewContents`. By 0: `setString`, `setData`, `writeObjects`, `addTypes`, reads |
| | | `attribution.theCountMovesBeforeTheTextIsThere` | confirmed, likewise | First read after the count moved found no string: `text` 1–4 of 50, `declare` 5–7 of 25, `rich` 7–14 of 25, a writer that works for 20 ms between clearing and writing 10 of 10 |
| | | `transaction.meetsTheCountBeforeTheText` | info | At a 1 ms poll, 1 of 60 captures in each run. Discarded runs of an earlier build saw 4 of 60 |
| A writer can tell whether it was alone | architecture §5, restore ("records its own post-restore count") | `count.clearingReturnsTheNewCount` | confirmed | `clearContents` and `declareTypes` return the count they leave |
| Both processes see one count | — | `count.isTheSameInBothProcesses` | confirmed | 0 rounds of 110 differed |
| Polling the count in the open transaction is affordable | architecture §5, waiting for the copy | `poll.isCheap`, `transaction.pollingAddsLittle` | confirmed | One read: p95 0.0006 ms; it is not a round trip to the server. A copy scripted for 5 ms was captured at p95 7.0–7.1 ms |
| Every item and representation can be copied and put back | ACT-10a, architecture §5 | `snapshot.roundTrips` ×11 kinds | confirmed | 5 of 5 each: same types, same order, same bytes. Text, RTF with HTML, three items, a file URL, the transient and concealed markers, 1, 10 and 50 MB, lazy data of 1 KB and 10 MB |
| A file promise can be recognised | ACT-10b | `snapshot.seesAFilePromise` | confirmed | Five types, every one with "promise" in its name (listed under Measurements) |
| Snapshot and restore fit the fallback read stage | PRD §11.1 | `snapshot.fitsTheFallbackReadStage` | confirmed | p95 for the pair: text 0.3 ms, 10 MB 4.2–6.9 ms, 50 MB 25.6–34.8 ms, of 270 ms |
| "Lazily provided data is read under the remaining budget" | architecture §5 | `snapshot.paysForLazyData` | confirmed that it costs what the provider costs | A provider that takes 50 ms makes the snapshot take 56 ms |
| | | `lazy.aHungProviderHoldsUpTheRead` | confirmed: **found** | `data(forType:)` was still blocked at 12 s and came back 1 ms after the provider's process was killed. A budget cannot be applied to a call that does not return |
| A dead owner's promise is not met by a snapshot | — | `lazy.aDeadOwnersPromiseIsDropped` `{typesReadFirst=false}` | confirmed | Nothing read while the owner lived: 1 representation listed afterwards, 0 unreadable |
| | | `{typesReadFirst=true}` | **refuted** | Types listed while it lived: 2 listed afterwards, 1 of them with no data. Why the two differ was not established |
| A delayed copy is caught by the drain | ACT-16c | `transaction.leavesNoHarm` `{lateCopyIntoTheDrain}` | confirmed | Copy at 400 ms, after the 250 ms window: taken and restored, 10 of 10 |
| | | `{copyAfterTheDrain}` | **refuted** | Copy at 900 ms, after the drain: the selection stayed on the pasteboard and the earlier copy was lost, 10 of 10 |
| A newer write wins | ACT-10f | `{foreignWriteAfterCapture}` | confirmed | Foreign write 20 ms after capture, before the restore: abandoned, the foreign write kept, 10 of 10 |
| An ambiguous change is abandoned | ACT-10d, 10g | `{foreignWriteFirst}` | **refuted** | Foreign write at 5 ms, the app's copy at 60 ms: the foreign text was taken for the selection, the foreign write was lost to the restore, and the app's copy then stayed on the pasteboard. 10 of 10 on each count |
| *(not in the design)* Watching on after the restore | — | `{foreignWriteFirst.watchingAfterRestore}` | refuted, but better | Still takes the wrong text and still loses the foreign write, but the app's late copy is caught and put back: left on the pasteboard 0 of 10 |
| Restore only if the count is still the captured one | ACT-10e, architecture §5 | `restore.checkThenClearIsNotOneStep` | confirmed, so **not a guarantee** | With another process writing about once a millisecond, 475–492 of about 3 200 restores had a write land between reading the count and clearing. The gap is p95 0.36 ms then, 0.13–0.15 ms with no other writer |
| A restore never ends up mixed with someone else's write | — | `restore.neverMixesWithANewerWrite` | confirmed | The count moved between our clear and the end of our write 408–454 times, and our write was refused in 303–335 of them. In the looks the count held still for, 0 pasteboards held our representation beside the other writer's text |
| macOS 15.4+ may prompt on programmatic reads | architecture §19 item 3 | `privacy.aProgrammaticReadIsHeldUp`, `privacy.pbcopyTextIsReadable` | **refuted** on this machine | `accessBehavior` is `alwaysAllow` before and after; the developer-preview key is unset. Text written by `pbcopy` was read back in 0.2–0.3 ms with no prompt. See the caveat under "What the log cannot know" |
| The spike leaves the user's clipboard as found | — | `general.putBackAsFound` | confirmed | Same types, order and bytes after the probe; the restore's clear was the only write |
| `InputEpoch` can be cross-checked without a tap | architecture §3.4 | `epoch.sessionCountersNeedNoPermission` | confirmed | `CGEventSource.counterForEventType` answers with no permission at all, p95 0.001 ms |
| The tap counts what the session counts | architecture §3.4 | `epoch.countsRealInput` | inconclusive | Nobody typed or clicked in the window |
| Our own tagged events are left out | architecture §3.4 | `epoch.leavesOutOurOwnEvents` | inconclusive | Needs an active tap and permission to post |

## Measurements

Milliseconds, as the range of the three files' values.

**Against the fallback read stage (270 ms)**

| Series | p50 | p95 | max | n per run |
|---|---|---|---|---|
| `poll.changeCountRead` general | 0.0005 | 0.0006 | 0.033–0.050 | 1 000 |
| `visibility.countSeenAfterTheClear` text (reader's clock against the writer's) | 0.006–0.012 | 0.044–0.050 | 0.069–0.088 | 50 |
| `visibility.textReadableAfterTheCount` text | 0.14–0.16 | 0.23–0.27 | 0.66–0.82 | 50 |
| …declare | 0.19–0.24 | 0.29–0.30 | 0.30–0.31 | 25 |
| …rich | 0.26–0.28 | 0.34–0.46 | 0.35–0.50 | 25 |
| `fixture.clearToWritten` text (the writer's own gap) | 0.018–0.021 | 0.028–0.039 | 0.057–0.106 | 50 |
| `transaction.untilCapture` promptCopy (copy scripted for 5 ms) | 6.95–7.06 | 7.02–7.11 | 7.02–7.11 | 10 |
| `transaction.open` promptCopy (snapshot to restored) | 9.6–10.8 | 11.5–12.2 | 11.5–12.2 | 10 |

The text is readable about a quarter of a millisecond after the count moves, though the writer itself needs only
0.02 ms between the two calls: most of the gap is the server and the reader, not the app.

**Snapshot and restore, by content** (n = 5 per run, so p95 is the max)

| Content | bytes | `snapshot.take` p50 | p95 | `snapshot.restore` p50 | p95 |
|---|---|---|---|---|---|
| text | 10 | 0.14–0.15 | 0.21–0.23 | 0.07–0.08 | 0.10–0.11 |
| rich (string, RTF, HTML) | 72 | 0.49–0.54 | 1.9–2.9 | 0.19–0.22 | 0.20–0.24 |
| three items | 93 | 0.29–0.43 | 0.40–0.47 | 0.14–0.16 | 0.16–0.17 |
| 1 MB | 1 000 010 | 0.33–0.37 | 0.36–0.40 | 0.18–0.20 | 0.20–0.22 |
| 10 MB | 10 000 010 | 2.8–3.4 | 3.1–4.7 | 1.0–2.1 | 1.1–2.2 |
| 50 MB | 50 000 010 | 14.1–16.6 | 14.3–21.3 | 5.8–11.0 | 10.0–14.1 |
| lazy, 1 KB, provider instant | 1 010 | 0.45–0.48 | 0.53–0.66 | 0.10–0.11 | 0.12–0.14 |
| lazy, 1 KB, provider takes 50 ms | 1 010 | 54.3–55.7 | 55.9–56.3 | 0.28–0.35 | 0.38–0.60 |
| lazy, 10 MB, provider instant | 10 000 010 | 5.7–6.1 | 9.1–14.4 | 1.4–2.7 | 2.4–5.2 |
| the user's real clipboard (3 representations, 62 bytes) | 62 | 2.1–2.2 | — | 0.12–0.14 | — |

A file promise from `NSFilePromiseProvider` shows as `com.apple.NSFilePromiseItemMetaData`,
`com.apple.pasteboard.promised-file-name`, `com.apple.pasteboard.promised-suggested-file-name`,
`com.apple.pasteboard.promised-file-content-type` and `com.apple.pasteboard.NSFilePromiseID`.

**Restore**

| Series | p50 | p95 | max | n per run |
|---|---|---|---|---|
| `restore.checkToClear` no other writer | 0.08–0.09 | 0.13–0.15 | 0.20–0.28 | 200 |
| `restore.checkToClear` another process writing each millisecond | 0.19–0.20 | 0.36 | 0.51–3.7 | about 3 200 |

## What the log cannot know

- **The Mac was shared.** From 13:47 UTC a test job of another project was running on it, and it was still running
  at 14:40. It starts small apps that come to the front (two starts 55 s apart when looked at), and one of its
  scripts is, by its own comments, a probe that presses keys in file panels, Return and ⌘W among them; how it
  presses them was not looked into. The crash below (14:19) and all three runs here (14:27 to
  14:29) fall inside that time. Found afterwards from the process list; whether it pressed a key or brought an app
  forward inside any one of these runs' windows is not known. Every time in this report was therefore taken with
  other work going on, and the three runs agreeing does not remove that, since they shared the condition. The counts
  and the transaction outcomes do not depend on load; the tails (p99, max) may. **One run on an idle machine is owed**
  before a figure from here goes into a budget.
- **One run died, and why is not settled.** A run of an earlier build crashed about four seconds into the
  input-counting window (`SIGSEGV`, no result file). The crash report shows the tap's callback called with event type
  `0xFFFFFFFF`, which is `tapDisabledByUserInput`, and a context pointer whose memory held zeroes where the handler
  closure should be, which is consistent with memory that had been freed. Two taps had been asked for in that run: an
  active one, refused for lack of permission, and the listen-only one in use. Which of them the context had belonged
  to is not known, and neither is what sent the notice. The tap's context is now an object of its own that is never
  freed, and tap-disabled notices are counted apart from input. The three runs here did not crash, but their tap also
  counted no input and no notice (`epoch.callbacksComeOnlyForALiveTap`: none, none, 0 events), so the condition that
  killed the earlier run has probably not been met again. The other project's job is the only known source of input
  on the machine at the time of the crash; that it had anything to do with the notice is not shown. **Treat this as open until a run with someone typing has passed.**
- **The privacy reading has a weak half.** The first read in the `general` part is of whatever was on the clipboard.
  In these three runs that was content a previous SpikeLab run had put back, so it says nothing about reading
  *another* app's data. The `pbcopy` read is the evidence: a different program wrote, SpikeLab read it 0.2–0.3 ms
  later. The run that crashed (above) did read another app's content first: 0.4 ms, 1 representation, by its log;
  it left no result file. No read took longer than 2.2 ms, which leaves no room for a prompt to have been up and answered.
  `pbcopy` is an Apple command-line tool, and whether a write from an ordinary third-party app is treated the same
  was not tried.
- The `general` part reads the user's real clipboard. It records counts and byte totals only, never type names or
  content, and it put the clipboard back as it found it in every run, the two markers aside: what was restored now
  carries `TransientType` and `ConcealedType`, which the original did not (ACT-10h, as designed).
- No system prompt appeared in any run, going by the absence of any blocked read.

## Consequences

- **Design changes** (proposed; `docs/architecture.md` §5 lists them as found and not yet designed in, and its state
  machine is unchanged):
  - *Attribution.* Split "the count advanced" from "holds a text type". When the count moves inside the window and
    no text type is there yet, wait and look again; abandon only when a short text wait runs out. The measured need
    is under 1 ms for a prompt writer, and an app that works between clearing and writing needs as long as it works,
    so the wait is policy data with a default of a few tens of milliseconds, spent from the same window.
  - *Snapshot.* Take it on a thread the broker can walk away from, with a deadline, and end in `Skipped` when the
    deadline passes. A snapshot on the broker actor's own executor would hang the broker with the source app. The
    abandoned thread stays blocked until the provider answers or dies; the design has to allow for one such thread
    outliving its transaction.
  - *Snapshot.* A representation that is listed and returns no data means `Skipped`, the same as a promise.
  - *Promises.* "Any type whose name contains `promise`" catches all five `NSFilePromiseProvider` types. Older
    `NSFilesPromisePboardType` and third-party lazy types were not tried.
  - *Restore.* Keep the count check, and compare what `clearContents` returns with the checked count plus one. When
    it is higher, a newer write was destroyed in the gap: that cannot be prevented, only known, and it should be
    logged as a safety event (ACT-10f). The gap is 0.13–0.15 ms wide at p95 when nothing else is writing.
  - *After the restore.* Add a state the design does not have: keep watching for the rest of the drain window after
    `Restored`, and put the snapshot back once more if an attributable change arrives. Without it, a transaction
    that captured the wrong write leaves the app's real copy on the clipboard.
  - *The first-writer hole.* A write from another program between the ⌘C and the app's copy is taken for the
    selection, and nothing the pasteboard offers tells them apart. Candidates, none tested: compare the captured
    text with what AX can see of the selection where AX gives anything; require the expected delta *and* no further
    change for a short settle time before capture (which would have caught this scenario, at the cost of that time
    on every fallback read); treat clipboard-manager apps in the running set as a reason to lengthen the settle.
    This needs a decision before the broker is built (M1 week 3).
  - *Drain.* Any finite drain leaves a later copy on the clipboard. The window has to come from the per-app tail of
    copy latency, which the `live` option measures and which has not been run. Apps whose tail is longer than a
    tolerable drain belong on the disable list for the clipboard fallback rather than on a longer drain.
- **Architecture §19 items this closes:** none fully. Item 3 (pasteboard privacy): not enforced by default on macOS
  26.4.1; open for macOS 15.4–15.x and the beta, and for the behaviour once a user turns it on in System Settings.
  `accessBehavior` is readable before any read, so the broker can check it and end in `Skipped` on `ask` or
  `alwaysDeny` without ever causing a prompt.
- **Budget changes (PRD §11.1):** none needed. Snapshot and restore take about 0.3 ms of the 270 ms stage for text.
  A size ceiling is not needed for time: 50 MB is 35 ms. If there is one it is for memory, and 50 MB is a
  defensible figure. A copy scripted for 5 ms was captured at 7 ms; those 2 ms include the fixture's own lateness as well as the 1 ms poll. Polling for a whole stage is 0.17 ms of CPU.
- **Paths disabled rather than weakened:** none yet. The candidates are apps with a long copy-latency tail; see
  "Not covered".
- **Licence:** no GPL-3.0 code was read or reused.

## Not covered

Everything that needs a permission or a person. SpikeLab has no Accessibility, Input Monitoring or post-event
access on this Mac, and granting them is the owner's decision.

- **The quiescence tier (RUN-2), which is half the question.** Whether the tap counts what the session counters
  count, whether tagged events are left out, how the frontmost-window check behaves across an app switch, and what
  window is safe. The `epoch` part is written and runs; it needs an active tap, permission to post, and someone
  typing for ten seconds. Run `Scripts/run-spike.sh spike-6-clipboard --state "accessibility + input monitoring"`.
- **Real apps.** `--enable live` sends ⌘C to the frontmost app five times and records the count delta, the time
  until the count moves, the time from the count to the text, and whether the restore was alone. Needed per app for
  the expected-delta range and the drain window: the Tier A lists of PRD §11.5, Word first among the tracked apps
  because of its stray-copy issue.
- **Source edits and app switches during a transaction**, and **destination verification** before a paste. Both
  need a real frontmost app and AX. They belong to the race suite of M1 week 3, with the per-app figures from `live`
  as inputs.
- **A concurrent user copy.** The scripted foreign write stands in for it on the pasteboard side. What differs with a
  real one is that `InputEpoch` advances, which is the untested half.
- **Pasteboard privacy switched on.** `defaults write app.pappuclip.SpikeLab EnablePasteboardPrivacyDeveloperPreview -bool YES`
  and a `general` run would show what enforcement looks like to the broker. Not done: it may raise a prompt that
  nobody was there to answer. The read is behind a 6 s deadline, so the run would survive it.
- **macOS 15 and the current beta.**
- The paste settle delay ("an app's read after ⌘V cannot be observed", architecture §5): nothing here measures it.
