# The M2 pass: installing, consenting and revoking by hand

This page is what M2's exit needs from a person. The tests do not cover it.

Every consent *decision* is already tested. `CapabilityAnalyzer` decides what the review lists, and `ConsentPresenter` which gates start off. The store decides what an approval covers. `ExtensionHost` decides that a revocation reaches the bar before it cancels the run. A few things are left, and only the real system can answer them:
- whether each install route reaches the one review;
- whether the Keychain keeps a secret and gives it back;
- whether a revocation stops a script that is really running;
- whether VoiceOver can read the review and the Extensions tab.

**Status: not yet run.** Build with `Scripts/build.sh PappuClip` and run the whole pass against that one build: the Accessibility grant is tied to its signature. Record a run by filling in the Result column, dating it, and naming the macOS build.

Fixtures:
- **A**: a URL snippet, `#popclip` / `name: Look Up` / `url: https://example.com/?q=***`.
- **B**: a shell snippet, `#popclip` / `name: Shout` / `shellScript: sleep 30; tr a-z A-Z`, with `after: paste-result`.
- **C**: a package with a `secret` option and a `.png` icon, zipped as `.popclipextz`.

## Every route reaches the review (EXM-2, EXM-5a)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 1 | Select the text of A in TextEdit | The bar's first button is **Install Extension "Look Up"** | |
| 2 | Press it | The bar goes away. "Install "Look Up"?" appears and says it is from this Mac, unsigned and unreviewed. It lists "Sends the selected text to example.com" | |
| 3 | Cancel | Nothing on the Extensions tab. No Look Up button on the next bar | |
| 4 | Repeat 1–2 and press Install | Look Up is on the next bar and runs | |
| 5 | Select A with 5,000 extra characters after it | **Install Extension**, dimmed; the tooltip says the selection is too long | |
| 6 | Double-click C in the Finder | The same review, from a file this time. After Install, the `.popclipextz` is gone (EXM-1) | |
| 7 | Open A again as a `.popcliptxt` file | The review says one called "Look Up" is already installed and will be installed beside it, not over it | |

## Gates start off (EXM-5d)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 8 | Install B, leaving the script switch alone | Installed. No Shout button on the bar | |
| 9 | Extensions tab → Shout → turn the script gate on | Shout is on the next bar | |

## Revoking stops what runs (SEC-4b)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 10 | Select a word in TextEdit, press Shout, and within 30 s choose Revoke Approval | The bar shows the action ended. Nothing is pasted into TextEdit. `ps` shows no `sleep 30` left | |
| 11 | Select text again | No Shout button. The Extensions tab says Revoked | |
| 12 | Approve again | Shout comes back only after its script gate is turned on again | |

## Options and the Keychain (ALM-6, §8.9, SEC-3)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 13 | Actions tab → C's gear. Type a secret and close | Keychain Access has one generic password under PappuClip's service, marked "this device only" | |
| 14 | Quit, relaunch and run C | The run gets the secret. The options sheet shows it as set | |
| 15 | Uninstall C | The Keychain item is gone | |
| 16 | Run a shell action that exits with status 2 | The bar shows an X, then Settings opens on that extension's options sheet | |
| 17 | Look at C's button before uninstalling | Its `.png` is drawn in the bar's colour, not as a coloured picture, unless it says `preserve-color` | |

## Automation (ONB-5)

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 18 | Run an AppleScript action that tells Music, and choose Don't Allow when macOS asks | An X, then the alert whose button opens Privacy & Security → Automation | |
| 19 | Allow it there and run it again | It runs, and no alert appears | |

## VoiceOver

| # | Do this | Expect | Result |
|---|---------|--------|--------|
| 20 | Move through the install review with VoiceOver | The title, each sentence, the provenance line and each gate switch are read, with its state | |
| 21 | Move through the Extensions tab | Each extension's name, state, capabilities and gates are read, and each switch says what it does | |
| 22 | Focus the dimmed Install Extension button from row 5 | Its name and the reason it is dimmed are read (BAR-17) | |

## What a failure here means

**Rows 1–7.** A failure there is a route that goes around `ConsentWindow`, which is the one place the "every route" claim rests on. Fix the route, not the review.

**Row 10.** If text is pasted after a revocation, `InvocationManager.invalidate(ownedBy:)` did not reach the run before its `after` step. That is a checkpoint missing in `ExtensionRunner`.

**Rows 13–15.** A failure there means `KeychainSecretStore`'s query attributes are wrong. The in-memory fake cannot catch that.
