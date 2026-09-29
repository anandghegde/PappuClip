import Foundation
import PappuCore
import PappuDiagnostics
@testable import PappuSettings
import PappuTestSupport
import Testing

/// DIA-3, DIA-4: the two switches in Settings, and what "Show What Is Sent" shows.
@MainActor @Suite struct DiagnosticsSettingsTests {
    private func model(_ channel: ReleaseChannel, storage: FakeSettingsStorage = FakeSettingsStorage()) -> DiagnosticsModel {
        let reporter = DiagnosticsReporter(
            preferences: DiagnosticsPreferences(storage: storage, channel: channel),
            environment: ReportEnvironment(
                app: VersionTriple(1), build: 1, channel: channel, macOS: VersionTriple(15), architecture: .arm64
            ),
            endpoints: DiagnosticsEndpoints(crashReports: nil, betaDiagnostics: nil),
            uploader: URLSessionDiagnosticsUploader(),
            storage: storage
        )
        return DiagnosticsModel(reporter: reporter)
    }

    @Test func bothSwitchesStartOff() {
        let model = model(.beta)
        #expect(!model.crashReports)
        #expect(!model.betaDiagnostics)
        #expect(model.offersBetaDiagnostics)
    }

    @Test func theSwitchesAreRemembered() {
        let storage = FakeSettingsStorage()
        let first = model(.beta, storage: storage)
        first.setCrashReports(true)
        first.setBetaDiagnostics(true)
        #expect(first.crashReports && first.betaDiagnostics)
        let second = model(.beta, storage: storage)
        #expect(second.crashReports && second.betaDiagnostics)
    }

    @Test func aReleaseBuildDoesNotOfferBetaDiagnostics() {
        for channel in [ReleaseChannel.release, .development] {
            let model = model(channel)
            #expect(!model.offersBetaDiagnostics)
            model.setBetaDiagnostics(true)
            #expect(!model.betaDiagnostics)
        }
    }

    @Test func thePreviewShowsOnlyWhatIsOn() throws {
        let model = model(.beta)
        model.showPreview()
        #expect(model.preview == DiagnosticsModel.Preview(crashReports: nil, betaDiagnostics: nil))

        model.setBetaDiagnostics(true)
        model.showPreview()
        let beta = try #require(model.preview?.betaDiagnostics)
        #expect(beta.contains("\"schema\""))
        #expect(model.preview?.crashReports == nil)

        model.hidePreview()
        #expect(model.preview == nil)
    }

    @Test func everyDiagnosticsStringIsInItsTable() {
        let missing = "\u{1}missing"
        for key in DiagnosticsStrings.all {
            #expect(
                DiagnosticsStrings.bundle.localizedString(forKey: key, value: missing, table: DiagnosticsStrings.table) != missing,
                "\(key) is not in Diagnostics.strings"
            )
        }
        #expect(Set(DiagnosticsStrings.all).count == DiagnosticsStrings.all.count)
    }
}
