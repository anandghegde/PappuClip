import Foundation
@testable import PappuApp
import PappuCore
import PappuExtensions
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

/// ONB-6's M3 half: the explanation and the offer, driven by the monitor's readings.
@MainActor
@Suite struct CoexistenceNoticeTests {
    private let popClip = "com.pilotmoon.popclip"
    private let running = Coexistence(popClipIsRunning: true, clipboardManagerIsRunning: false)

    /// A notice whose explanation answers `response`, counting how often it was shown.
    private final class Harness {
        let storage = FakeSettingsStorage()
        let rules: PrivacyRulesStore
        var asked = 0
        var howTo = 0
        var response: CoexistenceNotice.Response = .keepBoth
        var suppress = false
        private(set) var notice: CoexistenceNotice!

        @MainActor init() {
            rules = PrivacyRulesStore(storage: storage)
            notice = CoexistenceNotice(
                rules: rules,
                storage: storage,
                ask: { [unowned self] in
                    self.asked += 1
                    return (self.response, self.suppress)
                },
                showHowTo: { [unowned self] in self.howTo += 1 }
            )
        }
    }

    @Test func popClipStartingIsExplainedOnce() async {
        let harness = Harness()
        #expect(!(await harness.notice.note(.none)))
        #expect(await harness.notice.note(running))
        // Still running: nothing new to say.
        #expect(!(await harness.notice.note(running)))
        #expect(harness.asked == 1)
    }

    /// It is said again when PopClip quits and starts again.
    @Test func aRestartIsExplainedAgain() async {
        let harness = Harness()
        await harness.notice.note(running)
        await harness.notice.note(.none)
        await harness.notice.note(running)
        #expect(harness.asked == 2)
    }

    /// With automatic appearance off there are not two bars, and nothing to say.
    @Test func nothingIsSaidWhileAutomaticAppearanceIsOff() async {
        let harness = Harness()
        harness.rules.setAppearAutomatically(false)
        #expect(!(await harness.notice.note(running)))
        #expect(harness.asked == 0)
    }

    @Test func pausingTurnsOffAutomaticAppearance() async {
        let harness = Harness()
        harness.response = .pauseAutomaticAppearance
        await harness.notice.note(running)
        #expect(!harness.rules.appearAutomatically)
        #expect(harness.howTo == 0)
    }

    /// PopClip's bar is turned off by the user, in PopClip; PappuClip shows how and changes nothing
    /// of its own either.
    @Test func howToShowsTheStepsAndChangesNothing() async {
        let harness = Harness()
        harness.response = .showHowToTurnOffPopClip
        await harness.notice.note(running)
        #expect(harness.howTo == 1)
        #expect(harness.rules.appearAutomatically)
    }

    @Test func keepingBothChangesNothing() async {
        let harness = Harness()
        await harness.notice.note(running)
        #expect(harness.rules.appearAutomatically)
        #expect(harness.howTo == 0)
    }

    @Test func dontShowAgainIsRemembered() async {
        let harness = Harness()
        harness.suppress = true
        await harness.notice.note(running)
        await harness.notice.note(.none)
        #expect(!(await harness.notice.note(running)))
        #expect(harness.asked == 1)
        #expect(SettingsValue(key: CoexistenceNotice.suppressedKey, default: false, storage: harness.storage).value)
    }

    /// Through the monitor: PopClip already running at launch, and PopClip starting later, both reach
    /// the notice by the watcher alone (the injectable detection).
    @Test func theMonitorsReadingsReachIt() async throws {
        let harness = Harness()
        let apps = FakeRunningApplications(running: [popClip])
        let monitor = CoexistenceMonitor(watcher: apps)
        monitor.start()
        harness.notice.observe(monitor)
        try await waitUntil { harness.asked == 1 }

        apps.send([])
        apps.send([popClip])
        try await waitUntil { harness.asked == 2 }
        monitor.stop()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

/// ONB-6: the monitor says when the reading changes, and only then.
@Suite struct CoexistenceMonitorChangeTests {
    @Test func observersHearChangesOnly() {
        let apps = FakeRunningApplications()
        let monitor = CoexistenceMonitor(watcher: apps)
        let heard = Mutex<[Bool]>([])
        monitor.onChange { coexistence in heard.withLock { $0.append(coexistence.popClipIsRunning) } }
        monitor.start()
        apps.send(["com.pilotmoon.popclip"])
        apps.send(["com.pilotmoon.popclip", "com.example.editor"])
        apps.send([])
        #expect(heard.withLock { $0 } == [true, false])
    }

    /// While PopClip runs, what the chain and the coordinator are handed says so — the flag that takes
    /// synthetic copy off the automatic path (ACT-10j); the refusal itself is `SelectionStrategyChainTests`'.
    @Test func theFlagTheChainReadsFollowsALateLaunch() {
        let apps = FakeRunningApplications()
        let monitor = CoexistenceMonitor(watcher: apps)
        let reader = monitor.reader
        monitor.start()
        #expect(!reader().popClipIsRunning)
        apps.send(["com.pilotmoon.popclip"])
        #expect(reader().popClipIsRunning)
    }
}

/// EXM-11: the import's order — offer, one review, then the exclusions — with every system edge faked.
@MainActor
@Suite struct PopClipImporterTests {
    private final class Harness {
        let storage = FakeSettingsStorage()
        let rules: PrivacyRulesStore
        var found: PopClipImport?
        var accept = true
        var offers: [PopClipImporter.Offer] = []
        /// What the fake library does with the review's answer.
        var reviewAnswer: [ExtensionLibrary.BatchApproval]? = [.approve(granting: []), .leaveUnapproved]
        var installed: [[ExtensionLibrary.Source]] = []

        @MainActor init(found: PopClipImport?) {
            self.found = found
            rules = PrivacyRulesStore(storage: storage)
        }

        @MainActor func importer() -> PopClipImporter {
            let box = Mutex<PopClipImport?>(found)
            let answer = reviewAnswer
            return PopClipImporter(
                find: { box.withLock { $0 } },
                storage: storage,
                rules: rules,
                ask: { [unowned self] offer in
                    self.offers.append(offer)
                    return self.accept
                },
                install: { [unowned self] sources, review in
                    self.installed.append(sources)
                    // Stands in for the library: every source is reviewed, then activated as answered.
                    guard let answers = await review([]), answers.count == sources.count else {
                        return sources.map { .init(source: $0, result: .success(.cancelled)) }
                    }
                    return zip(sources, answers).map { source, answer in
                        let identity = LocalIdentity()
                        switch answer {
                        case .approve: return .init(source: source, result: .success(.installed(identity, replaced: nil)), approved: true)
                        case .leaveUnapproved: return .init(source: source, result: .success(.installed(identity, replaced: nil)), approved: false)
                        case .skip: return .init(source: source, result: .success(.cancelled))
                        }
                    }
                },
                review: { _ in answer }
            )
        }
    }

    private static let found = PopClipImport(
        packages: [URL(filePath: "/p/Search.popclipext"), URL(filePath: "/p/Shout.popclipext")],
        excludedApps: ["com.apple.Terminal", "com.example.ruled", "com.example.blocked"]
    )

    @Test func withoutPopClipsFolderNothingIsOffered() async {
        let harness = Harness(found: nil)
        let importer = harness.importer()
        #expect(!importer.isAvailable)
        #expect(await importer.offerAtFirstRun() == nil)
        #expect(await importer.importNow() == nil)
        #expect(harness.offers.isEmpty)
    }

    /// The first-run offer is made once; the menu can make it again.
    @Test func theFirstRunOfferIsMadeOnce() async {
        let harness = Harness(found: Self.found)
        harness.accept = false
        let importer = harness.importer()
        #expect(await importer.offerAtFirstRun() == nil)
        #expect(await importer.offerAtFirstRun() == nil)
        #expect(harness.offers == [.init(extensions: 2, excludedApps: 3)])
        _ = await importer.importNow()
        #expect(harness.offers.count == 2)
    }

    /// Declining imports nothing: no install, no exclusions.
    @Test func decliningTheOfferImportsNothing() async {
        let harness = Harness(found: Self.found)
        harness.accept = false
        _ = await harness.importer().importNow()
        #expect(harness.installed.isEmpty)
        #expect(harness.rules.rules.appModes.isEmpty)
    }

    /// EXM-11 with EXM-15d: imported folders go to the batch review as PopClip packages, and the report
    /// says which arrived turned off.
    @Test func theImportReportsWhatIsWaiting() async throws {
        let harness = Harness(found: Self.found)
        let report = try #require(await harness.importer().importNow())
        #expect(harness.installed == [Self.found.packages.map(ExtensionLibrary.Source.popClipPackage)])
        #expect(report.approved == ["Search"])
        #expect(report.waiting == ["Shout"])
        #expect(!report.cancelled)
    }

    /// PopClip's exclusions become appearance exclusions, leaving any rule the user already has.
    @Test func exclusionsArriveAsAppearanceExclusionsWithoutOverridingRules() async throws {
        let harness = Harness(found: Self.found)
        harness.rules.setMode(.off, forApp: "com.example.ruled")
        harness.rules.setHardBlocked(true, forApp: "com.example.blocked")
        let report = try #require(await harness.importer().importNow())
        #expect(report.excludedApps == ["com.apple.Terminal"])
        #expect(harness.rules.rules.appModes["com.apple.Terminal"] == .hotkeyOnly)
        #expect(harness.rules.rules.appModes["com.example.ruled"] == .off)
        #expect(harness.rules.rules.appModes["com.example.blocked"] == nil)
    }

    /// A cancelled review brings nothing across, not even the exclusions.
    @Test func cancellingTheReviewImportsNoExclusions() async throws {
        let harness = Harness(found: Self.found)
        harness.reviewAnswer = nil
        let report = try #require(await harness.importer().importNow())
        #expect(report.cancelled)
        #expect(harness.rules.rules.appModes.isEmpty)
        #expect(PopClipStrings.summary(report) == nil)
    }

    /// With no packages there is no review, and the exclusions come across on the offer's say-so.
    @Test func exclusionsAloneNeedOnlyTheOffer() async throws {
        let harness = Harness(found: PopClipImport(packages: [], excludedApps: ["com.apple.Terminal"]))
        let report = try #require(await harness.importer().importNow())
        #expect(harness.installed.isEmpty)
        #expect(report.excludedApps == ["com.apple.Terminal"])
    }
}

@Suite struct PopClipStringsTests {
    @Test func everyStringTheImportAndTheNoticeSayIsInTheCatalogue() {
        let bundle = PopClipStrings.bundle
        for key in PopClipStrings.all {
            let missing = "\u{1}missing\u{1}"
            #expect(
                bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                "\(key) has no entry in Localizable.strings"
            )
        }
    }

    @Test func theOfferSaysTheCounts() {
        let body = PopClipStrings.offerBody(extensions: 12, excludedApps: 3)
        #expect(body.contains("12"))
        #expect(body.contains("3"))
    }

    @Test func theSummarySaysWhatIsWaiting() throws {
        var report = PopClipImporter.Report()
        report.waiting = ["Shout"]
        let text = try #require(PopClipStrings.summary(report))
        #expect(text.contains("Shout"))
        #expect(PopClipStrings.summary(PopClipImporter.Report()) == PopClipStrings.resultNothing)
    }
}
