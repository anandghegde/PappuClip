import Foundation
import PappuApp
import PappuCore
import Testing

/// PRD §7.5 and ACT-18: what the menu bar offers, and what it says about a pause.
@Suite struct MenuBarMenuTests {
    private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func nothingIsPausedOnAFreshInstallAndBothPausesAreOffered() {
        let menu = MenuBarMenu(rules: PrivacyRules(), now: noon)
        #expect(!menu.isPaused)
        #expect(menu.statusLine == nil)
        #expect(menu.commands == [.appearAutomatically, .pauseForOneHour, .pauseUntilResumed, .settings, .debugConsole, .quit])
    }

    /// While paused there is one pause command and it is the way out. Offering "Pause for One Hour"
    /// beside "Resume" would offer to restart a pause that is already running.
    @Test func aPausedMenuOffersResumeAndNeitherPause() {
        let menu = MenuBarMenu(rules: PrivacyRules(pause: .untilResumed), now: noon)
        #expect(menu.isPaused)
        #expect(menu.commands == [.appearAutomatically, .resume, .settings, .debugConsole, .quit])
    }

    @Test func aPauseWithNoEndSaysOnlyThatItIsPaused() {
        let menu = MenuBarMenu(rules: PrivacyRules(pause: .untilResumed), now: noon)
        #expect(menu.statusLine == AppStrings.pausedUntilResumed)
    }

    /// A time of day and not a countdown: the pause survives a quit, and a remaining-minutes line would
    /// be wrong the moment the menu stayed open.
    @Test func aTimedPauseNamesTheTimeItEnds() {
        let menu = MenuBarMenu(
            rules: PrivacyRules(pause: .forOneHour(from: noon)),
            now: noon,
            locale: Locale(identifier: "en_US")
        )
        let expected = (noon + PauseState.oneHour)
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_US")))
        #expect(menu.statusLine == AppStrings.pausedUntil(expected))
    }

    /// Nothing schedules a timer, so an expiry that has gone by has to read as running here too —
    /// otherwise the menu would go on saying "Paused" for an hour that is over.
    @Test func aPauseWhoseHourIsUpIsNotAPause() {
        let menu = MenuBarMenu(
            rules: PrivacyRules(pause: .forOneHour(from: noon)),
            now: noon + PauseState.oneHour
        )
        #expect(!menu.isPaused)
        #expect(menu.statusLine == nil)
        #expect(menu.commands.contains(.pauseForOneHour))
    }

    @Test func theTickFollowsTheAppearAutomaticallySetting() {
        #expect(MenuBarMenu(rules: PrivacyRules(), now: noon).item(.appearAutomatically)?.isOn == true)
        let off = MenuBarMenu(rules: PrivacyRules(appearAutomatically: false), now: noon)
        #expect(off.item(.appearAutomatically)?.isOn == false)
    }

    /// ONB-1: the reason nothing else works goes first, because a user who reaches the menu after
    /// pressing the shortcut and seeing nothing is looking for exactly this.
    @Test func aMissingGrantIsTheFirstThingInTheMenu() {
        let menu = MenuBarMenu(rules: PrivacyRules(), grant: .notTrusted, now: noon)
        #expect(menu.commands.first == .onboarding)
        #expect(menu.item(.onboarding)?.title == AppStrings.accessibilityMissing)
    }

    /// ONB-4 reads differently from ONB-1. The tick is already there, and telling the user to grant a
    /// permission they can see they have granted sends them in a circle.
    @Test func aStaleGrantSaysSomethingElse() {
        let menu = MenuBarMenu(rules: PrivacyRules(), grant: .stale, now: noon)
        #expect(menu.item(.onboarding)?.title == AppStrings.accessibilityStale)
    }

    /// The ordinary state of a launch where nothing has asked for a bar yet. A warning here would be a
    /// warning in every quiet moment.
    @Test func anUntestedGrantSaysNothing() {
        let menu = MenuBarMenu(rules: PrivacyRules(), grant: .untested, now: noon)
        #expect(!menu.commands.contains(.onboarding))
    }

    @Test func settingsAndQuitKeepTheirShortcuts() {
        let menu = MenuBarMenu(rules: PrivacyRules(), now: noon)
        #expect(menu.item(.settings)?.keyEquivalent == ",")
        #expect(menu.item(.quit)?.keyEquivalent == "q")
        #expect(menu.item(.appearAutomatically)?.keyEquivalent == nil)
    }

    /// A menu that opens with a dividing line, or has two in a row, looks broken. The layout is built by
    /// appending, so this is the assertion that keeps an added section from leaving one behind.
    @Test func noDividingLineIsStrandedInAnyState() {
        let states: [(PrivacyRules, AccessibilityGrant)] = [
            (PrivacyRules(), .working),
            (PrivacyRules(), .notTrusted),
            (PrivacyRules(pause: .untilResumed), .working),
            (PrivacyRules(pause: .untilResumed), .stale),
            (PrivacyRules(appearAutomatically: false, pause: .forOneHour(from: noon)), .notTrusted),
        ]
        for (rules, grant) in states {
            let entries = MenuBarMenu(rules: rules, grant: grant, now: noon).entries
            #expect(entries.first != .separator)
            #expect(entries.last != .separator)
            #expect(!zip(entries, entries.dropFirst()).contains { $0 == .separator && $1 == .separator })
        }
    }

    /// Every command the menu can show is one the app has an answer for. `CaseIterable` is what the
    /// switch that carries them out is written over, so an added case with nowhere to go is a build
    /// failure there and a visible gap here.
    @Test func everyCommandIsReachableFromSomeState() {
        let shown = Set(MenuBarMenu(rules: PrivacyRules(), grant: .notTrusted, now: noon).commands)
            .union(MenuBarMenu(rules: PrivacyRules(pause: .untilResumed), now: noon).commands)
        #expect(shown == Set(MenuCommand.allCases))
    }
}

@Suite struct AppStringsTests {
    @Test func everyStringTheAppSaysIsInTheCatalogue() {
        let bundle = AppStrings.bundle
        for key in AppStrings.all {
            let missing = "\u{1}missing\u{1}"
            #expect(
                bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                "\(key) has no entry in Localizable.strings"
            )
        }
    }

    @Test func thePauseStatusPutsTheTimeIntoTheSentence() {
        #expect(AppStrings.pausedUntil("1:23 PM").contains("1:23 PM"))
    }
}
