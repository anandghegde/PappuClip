# The M1 pass — pasting into real apps

RUN-4's half that no test can hold, the two RUN-5 scenarios whose fakes deserve a witness, and the
Accessibility grant, which only a real trust database can change.

Everything about a mutation that is a *decision* is covered by `PappuRuntimeTests` and
`PappuSelectionTests`: which tier was reached, whether the run was still live, what went on the pasteboard,
that it came back off again, and that nothing is written when the destination cannot be verified. What is
left is the one thing only another app's undo manager can answer — **is one action one ⌘Z?** — and whether
`ClipboardTiming.holdMs` is long enough for apps we do not own. That is this page.

**Status: not yet run.** The app it needs now exists — `Scripts/build.sh PappuClip` builds and signs
`build/DerivedData/Build/Products/Debug/PappuClip.app`, and the grant is tied to that signature, so the
whole pass has to be run against one build. Record a run by filling in the Result column, dating it, and
naming the macOS build and the version of each app.

## Before

1. Accessibility grant in place (`Scripts/run-spike.sh` refuses without it).
2. **No clipboard manager running.** ACT-10i's matrix is its own pass, against named managers; this one is
   about the app being pasted into, and a manager in the middle confuses the two.
3. Put something recognisable on the clipboard first — `MANUAL CHECK CLIPBOARD` — so that "their clipboard
   came back" is something you can see rather than something you assume.
4. Have the inspector's records to hand: each row's `ClipboardPasteRecord` says `held`, `restored` and any
   safety event, and a row that passes by eye while recording `destroyedANewerWrite` has not passed.

## The grant, live (ONB-1, ONB-4)

`OnboardingState` decides which screen is owed and `OnboardingModel` closes the window when the grant
arrives; both are tested. What no test can do is change the trust database, which is the input those rules
read — so these rows are the ones that say `AccessibilityMonitor` is watching the right notification and
that `CGEvent.tapCreate` tells a working grant from a stale one.

Run rows 16–18 on a machine where PappuClip has never been granted: `tccutil reset Accessibility
app.pappuclip.PappuClip` puts one back into that state, and the system's prompt appears once per install
for a process that is not trusted.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 16 | Launch a build that has never been granted | The welcome window, and a status item in the menu bar. No Dock icon | |
| 17 | Press Continue | The system's prompt, and behind it the permission screen with the direct link | |
| 18 | Open the pane from that screen and tick PappuClip | The window closes **by itself**. Nothing was pressed to dismiss it | |
| 19 | Select text in TextEdit | The bar appears — the grant took effect without a relaunch | |
| 20 | Untick PappuClip in the pane while the app is running | "Accessibility Permission Needed…" is the first item in the menu, and no bar appears on selection | |
| 21 | Tick it again | The menu item goes away and selection works again | |
| 22 | Rebuild with a different signature and launch without re-granting | "Repair Accessibility Permission…" rather than the ask again, and the repair screen says to remove and re-add (ONB-4) | |

Row 22 is the one worth the trouble to stage: `AccessibilityGrant.stale` is the state the code goes to
lengths to tell apart from `notTrusted`, and it is invisible to every test because both facts it reads —
`AXIsProcessTrusted` and whether a tap was created — are faked there. To stage it, delete the "PappuClip
Development" identity from the login keychain and run `Scripts/setup-dev-signing.sh` again: the script
does nothing while the identity exists, and makes a new certificate of the same name once it is gone. The
trust database's entry still matches the name and no longer matches the key, which is exactly the state a
macOS upgrade leaves behind.

## The undo pass (RUN-4)

For each app: select a few words, run ⇧ Paste over them — the one M1 built-in that replaces text through `TextMutator` — then press ⌘Z
**once**.

| # | App | Expect | Result |
|---|-----|--------|--------|
| 1 | TextEdit, rich text | One ⌘Z brings back exactly the original words, with their formatting | |
| 2 | TextEdit, plain text (⇧⌘T) | Same, and no stray paragraph styling arrives with the paste | |
| 3 | Notes | One ⌘Z, one restore. Notes is the app whose undo coalescing this is most likely to surprise | |
| 4 | Mail, a message being composed | One ⌘Z; the quoted text below is untouched | |
| 5 | Safari, a plain `<input>` | One ⌘Z | |
| 6 | Safari, a `contenteditable` (any rich web editor) | One ⌘Z, not one per character | |
| 7 | Xcode, a source file | One ⌘Z, and the edit is one entry in the editor's history | |
| 8 | An Electron editor (VS Code) | One ⌘Z | |

A row where ⌘Z does nothing, or undoes the edit *before* ours, is RUN-4 failing — and it is the reason the
mutator posts a keystroke instead of writing `AXSelectedText`, so it failing would be worth a spike rather
than a patch.

## The clipboard's round trip (ACT-10f, ACT-10h)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 9 | Any row above, then ⌘V into a scratch document | `MANUAL CHECK CLIPBOARD` — their clipboard, not the action's result | |
| 10 | Watch the pasteboard through the inspector during a replace | The result is up for about `ClipboardTiming.holdMs`, then gone | |
| 11 | Replace in the slowest app on the list | The paste lands. If it does not, the hold is too short and `holdMs` is the number to move | |
| 12 | Copy something in another app *while* a slow action is finishing | The stranger's write survives; the record says `foreignWriteWhileHeld`; the user's clipboard is **not** restored over it | |

Row 11 is the one this page exists for as much as the undo rows. `holdMs` is marked **provisional** in
`ClipboardTiming` because a paste is unobservable — nothing moves the change count, no type appears — so the
hold is a two-sided guess: too short and the app pastes the user's own clipboard over their selection, too
long and their clipboard is missing for no reason. A run of this page is what turns it into a measurement.

## RUN-5, where a fake cannot be trusted

Both scenarios are unit tests already (`closingTheSourceWindowWritesNothingIntoWhateverIsBehindIt`,
`aQuiescenceVerifiedPasteTurnsOnWhetherAnythingWasTyped`). These rows check that the real
`AXDestinationProbe` sees what `FakeDestinationProbe` was told to say.

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 13 | Select in a Notes window, start a slow action, close that window before it finishes | Nothing is written into the window behind it; the run ends blocked, naming the window | |
| 14 | Select in Terminal (no Accessibility selection to read), run a replacing action | Refused at the quiescence tier, or verified and pasted — never verified at the Accessibility tier | |
| 15 | Same as 14, but type one character before the action finishes | Refused, and the reason names the keystroke | |

## What a failure here means

Rows 1–8 failing is a fact about an app's undo manager, and the answer is a detection policy field, not a fix
in `TextMutator`. Rows 9–12 failing is a bug in `ClipboardBroker`'s write path, which is fully covered by
tests — so a failure there means the `ScriptedPasteboard` model is wrong about the real `NSPasteboard`, and
the model is what to change first. Rows 13–15 failing is a bug in `AXDestinationProbe`, the one part of the
verification no test can reach.
