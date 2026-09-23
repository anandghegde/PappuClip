# VoiceOver pass — the bar

BAR-14's half that no test can hold. Everything the requirement asks for that is a *decision* lives in a value
type and is covered by `PappuSurfacesTests` — which string is said, when a change is announced, what Reduce
Motion and Reduce Transparency and Increase Contrast turn into. What is left is whether VoiceOver, running for
real over a real `NSPanel`, actually reads any of it. That is this page.

**Status: not yet run.** It needs a bar on a screen, which needs the Accessibility grant and spike 1's SpikeLab
entry. Record a run by filling in the table below, dating it, and naming the macOS build.

## Before

1. Accessibility grant in place (`Scripts/run-spike.sh` refuses without it).
2. VoiceOver on (⌘F5). Verbosity default; no custom activity.
3. Show a bar with more than one button — three is enough to move through.

## The pass

| # | Do this | Expect | Requirement | Result |
|---|---------|--------|-------------|--------|
| 1 | Make a bar appear | VoiceOver says "PappuClip actions" without the user going looking for it | BAR-14, `barAppeared` | |
| 2 | Route the VoiceOver cursor onto the bar (⌃⌥ with the pointer over it) | The bar is a group, named, and its buttons are its children in left-to-right order | BAR-14 | |
| 3 | ⌃⌥→ across the buttons | Each one reads its action name and the role "button" | BAR-6, BAR-14 | |
| 4 | Land on a disabled button | It reads as dimmed and says why, not just the name | BAR-17 (M3), BAR-14 | |
| 5 | → on the bar itself (not VoiceOver navigation) | The highlight moves and the newly highlighted button's name is announced | BAR-9a, BAR-14 | |
| 6 | ⌃⌥space on a button | The action runs, once | BAR-14 | |
| 7 | Run something slow | "Working" is announced as the spinner appears | BAR-12a, BAR-14 | |
| 8 | Let it finish | "Done" — or "Copied", or the failure — is announced once, not twice | BAR-12a | |
| 9 | Esc | The bar goes, and VoiceOver's cursor lands back where it was, not on nothing | BAR-10, BAR-1 | |
| 10 | While the bar is up, check the app underneath still has key focus | The app's own caret is where it was; the bar never became key | BAR-1 | |

## The three accessibility settings

Each is set in System Settings → Accessibility → Display, with a bar up, and the bar is made to appear again
after the change.

| # | Setting | Expect | Requirement | Result |
|---|---------|--------|-------------|--------|
| 11 | Reduce Motion | The failure X does not shake; the spinner still turns | BAR-14 | |
| 12 | Reduce Transparency | The background is solid, not vibrant | BAR-14 | |
| 13 | Increase Contrast | A border appears, the background is solid, and the highlight is a plain fill rather than an accent tint | BAR-14 | |

## What a failure here means

A row that fails is a bug in `BarPanel.swift` — the only file in `PappuSurfaces` that no test covers, and the
only one that talks to AppKit. The rules it is drawing from are already asserted; if a row fails, the value it
was handed was right and something between it and the screen dropped it.
