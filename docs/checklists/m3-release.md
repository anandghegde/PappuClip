# The M3 pass: a signed release and Settings → App by hand

This page covers what a release needs from a person: a Developer ID signature, notarization, and a Sparkle update from one version to the next. None of these can happen without real credentials. It also covers the parts of Settings → App that only the system can confirm.

`ReleaseConfigurationTests` checks the entitlements, the Info.plist keys and the release script as they are checked in. `AppTabTests` checks the App tab's model against a fake updater and a fake login item. `Scripts/release.sh --local` builds and signs everything with the development certificate and runs `Scripts/verify-signature.sh`, all without Apple credentials.

**Status: week 7; not yet run.** Record a run by filling in the Result column, dating it, and naming the macOS build.

## Setup, once

Nothing here is ever committed.

- A **Developer ID Application** certificate in the login keychain: `security find-identity -v -p codesigning` lists it.
- **A notarytool profile.** Run `xcrun notarytool store-credentials pappuclip-notary --apple-id <id> --team-id <team>` with an app-specific password.
- **The EdDSA key pair.** Run `Scripts/appcast.sh --generate-keys` once. Back it up with `generate_keys -x <file>` somewhere outside the repository. If it is lost, no copy already in the field can update again.
- **The environment:**
  - `PAPPU_RELEASE_IDENTITY="Developer ID Application: … (TEAM)"`
  - `PAPPU_NOTARY_PROFILE=pappuclip-notary`
  - `PAPPU_SPARKLE_PUBLIC_KEY=$(Scripts/appcast.sh --print-public-key)`
  - `PAPPU_APPCAST_URL=https://…/appcast.xml`

## Signing and notarization (PRD §11.4)

| # | Step | Expected | Result |
|---|------|----------|--------|
| R1 | Run `Scripts/release.sh` with none of the four variables set. | It exits 1 and names all four. Nothing is built. | |
| R2 | Run `Scripts/release.sh --local`. | It builds, signs with the development identity, and every line of the verification says `ok`. The zip and DMG are named `-local`. | |
| R3 | Run `Scripts/release.sh --version 0.9.0 --build 90` with the setup above. | Notarization is `Accepted` for the app and for the DMG. `stapler validate` and `spctl --assess` pass. | |
| R4 | Run `codesign -dvv --entitlements - PappuClip.app` and the same on each `.xpc` in the stage folder. | The Authority is Developer ID with a TeamIdentifier and a timestamp, and `flags=0x10000(runtime)`. The app has only disable-library-validation=false, the Runner only apple-events, and the JSHost only the sandbox. None has get-task-allow. | |
| R5 | On a clean Mac, or one that has never seen a build, download the DMG through a browser, open it, drag the app to Applications, and launch it. | Gatekeeper shows only the "downloaded from the Internet" prompt, with no warning about an unidentified developer. The app starts and asks for Accessibility. | |
| R6 | Disconnect from the network and launch again. | It starts, because the stapled ticket is used offline. | |
| R7 | Use an extension that runs JavaScript and one that runs AppleScript. | Both helpers start from the notarized bundle, and neither shows a code-signing error in Console. | |

## Sparkle updates (PRD §11.4)

| # | Step | Expected | Result |
|---|------|----------|--------|
| U1 | Release build 90, put its zip in an archives folder, and run `Scripts/appcast.sh <folder> --download-url-prefix https://…/`. Upload the result. | `appcast.xml` has one item with `sparkle:edSignature`. | |
| U2 | Install build 90. Release build 91 the same way and publish it. In Settings → App, choose **Check for Updates Now**. | Sparkle offers 0.9.1, downloads it, checks the signature, and relaunches into 91. The Runner and JSHost of 91 answer (R7). | |
| U3 | Re-sign build 92's zip with a different EdDSA key, or give `appcast.sh` a mismatched key. | `appcast.sh` refuses to write an unsigned item. If an item is forced through by hand, the app refuses the update. | |
| U4 | Publish build 93 with `--channel beta`. Check for Updates Now with **Include beta versions** off, then with it on. | With it off, the app is up to date. With it on, 93 is offered. | |
| U5 | Set Software Update to **Off**, then quit and relaunch. Then set it to **Install automatically**. | Off makes no scheduled check (Console, subsystem `org.sparkle-project.Sparkle`). With Install automatically, the next scheduled check installs silently on quit. | |
| U6 | First launch of a fresh install. | Sparkle's own "check automatically?" prompt does not appear (`SUEnableAutomaticChecks` is set), and the policy reads **Notify only**. | |

## Settings → App (PRD §7.5)

| # | Step | Expected | Result |
|---|------|----------|--------|
| A1 | Open Settings → App in a development build. | The version shows. Software Update is disabled, with the sentence saying this copy does not update itself. Check for Updates Now is dimmed. | |
| A2 | Turn **Start at login** on, then log out and back in. | PappuClip starts and appears in System Settings → General → Login Items under its own name. | |
| A3 | Remove it in System Settings, then reopen the App tab. | The switch is off. | |
| A4 | Run a copy from outside /Applications, such as a DMG that is still mounted. | Start at login is dimmed or says it cannot be used from this copy, and it never registers the DMG's path. | |
| A5 | Use **Source Code**, **Report an Issue**, and **Open Debug Console**. | The repository opens, then its issues page, and the Debug Console window comes forward. | |
| A6 | With VoiceOver, go through the App tab. | Every control reads its label. The policy picker and the beta toggle read their hints. Nothing reads as "button" alone. | |
| A7 | Look at the space between Startup and Troubleshooting. | Empty for now. The DIA-3/DIA-4 opt-in toggles go there (`AppTabView.diagnosticsSection`). | |
