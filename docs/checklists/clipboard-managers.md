# The ACT-10i pass — clipboard managers

ACT-10i asks for two things: clipboard-manager interoperability verified against a named list, and the
results published. It also forbids a claim: **nothing here may say that PappuClip's writes are invisible to
another app.** `TransientType` and `ConcealedType` are requests a manager may ignore, and a row that finds
one ignoring them is a result to publish, not a failure to hide.

Everything about the transaction that is a *decision* is covered by `ClipboardBrokerTests` and
`ClipboardRaceTests`. What is left is what only a real manager can show: whether it honours the markers,
whether its own reads and rewrites after a copy are slow enough to break attribution at the managed
settle (`ClipboardTiming.managerSettleMs`), and whether `CoexistenceMonitor` sees it at all.

**Status: not yet run.** Record a run by filling in the tables, dating it, and naming the macOS build and
each manager's version and settings (history on or off, "ignore transient" on or off where it exists).

## The list

The bundle identifiers are `Coexistence.clipboardManagerBundleIDs`, and every one of them is unverified
until a row below confirms it. A manager that is not on that list gets the short settle, so a manager found
running but not detected (column D) is the most important thing this page can find: add its identifier
to the list in the same change that records the row.

| Manager | Bundle ID in the code | D: detected | Version | Settings |
|---|---|---|---|---|
| Maccy | `org.p0deje.Maccy` | | | |
| Paste | `com.wiheads.paste`, `com.wiheads.paste-setapp` | | | |
| Pastebot | `com.tapbots.Pastebot2Mac` | | | |
| Clipy | `com.clipy-app.Clipy` | | | |
| Flycut | `com.generalarcade.flycut` | | | |
| CopyClip 2 | `com.fiplab.copyclip2` | | | |
| Alfred (Clipboard History on) | `com.runningwithcrayons.Alfred` | | | |
| Raycast (Clipboard History on) | `com.raycast.macos` | | | |

To fill in D: with only that manager running, the inspector's `ClipboardTransactionRecord` for any
synthetic copy says `clipboardManagerIsRunning: true`. Confirm the identifier with
`osascript -e 'id of app "<name>"'`.

## Before

1. Accessibility grant in place, and the build under test is the one that was granted (see `m1-manual.md`).
2. **One manager at a time.** Two managers reading the same pasteboard is a different experiment.
3. PopClip not running: it takes synthetic copy off the automatic path, and the automatic path is where
   most of these rows happen.
4. Put `MANUAL CHECK CLIPBOARD` on the clipboard, so that "it came back" is something seen.
5. Use an app whose detection policy allows strategy 5 on the route under test, and a selection that
   strategies 1–3 cannot read — otherwise no synthetic copy happens and the row tests nothing.

## Per manager

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 1 | Select text so the bar appears by synthetic copy; open the manager's history | The selection is **not** a new history entry. If it is, the manager ignores `TransientType`: record it — it is a published result, not a bug | |
| 2 | Same, then ⌘V in a scratch document | `MANUAL CHECK CLIPBOARD`. The record says `restored`, with no safety event | |
| 3 | Run ⇧ Paste over a selection (the M1 built-in that replaces through `TextMutator`) and open the history | The pasted text is not a second entry, or is recorded as one if the manager ignores the markers | |
| 4 | Twenty synthetic-copy selections in a row, at a normal pace | Every record's outcome is `copied`; none is `ambiguous` and none carries a safety event. A manager that rewrites after each copy shows up here first, and `managerSettleMs` is the number to move | |
| 5 | Copy something with ⌘C in another app while a bar is appearing | The user's copy survives and is in the history. The record is `ambiguous` or carries `foreignWriteBeforeRestore` or `foreignWriteDuringDrain`, and `restored` is false: nothing was put back over it (ACT-10f) | |
| 6 | Pick an older entry from the manager's history while ⇧ Paste holds the clipboard | The manager's write survives; the paste record says `foreignWriteWhileHeld` | |

A row 4 that fails at `managerSettleMs` but passes with the manager quit is the finding this page exists
for. It means the settle is too short for that manager, and the change is a number, recorded here with
the run that justified it.

## Publishing

When a run is complete, copy the tables into `Tests/results/clipboard-managers/<date>.md` with the macOS
build, and link that file from the README. Rows 1 and 3 are the ones users
will ask about: say plainly which managers record PappuClip's reads and which do not.
