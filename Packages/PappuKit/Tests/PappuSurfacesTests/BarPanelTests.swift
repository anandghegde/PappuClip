import Foundation
import PappuSurfaces
import Testing

/// BAR-1 and BAR-2 as the panel is configured, and PRD §7.12 as the strings are written.
///
/// The panel itself is not built here. A test process has no window server, and `NSPanel.init` takes
/// the process down rather than failing, so there is nothing to be learnt by trying. What is asserted
/// is the value the panel is built from — which is the whole reason `BarPanelConfiguration` is a value
/// and not a pile of statements inside `prepare()`. The panel is spike 1's to run by hand.
@Suite struct BarPanelTests {

    @Test func theBarCanNeverBecomeKey() {
        #expect(!BarPanelConfiguration.bar.canBecomeKey)
        #expect(BarPanelConfiguration.bar.isNonActivating)
    }

    @Test func theBarIsThereInEverySpaceAndOverAFullscreenApp() {
        #expect(BarPanelConfiguration.bar.joinsAllSpaces)
        #expect(BarPanelConfiguration.bar.isFullScreenAuxiliary)
    }

    @Test func theBarDoesNotHideWhenWeAreNotTheActiveApp() {
        // PappuClip is an accessory app and is never active, so a panel that hid on deactivation
        // would never be seen at all.
        #expect(!BarPanelConfiguration.bar.hidesOnDeactivate)
        #expect(BarPanelConfiguration.bar.isBorderless)
    }

    @Test func theBarSitsAtThePopUpMenuLevelUntilSpikeOneSaysOtherwise() {
        // Provisional: spike 1 runs the level × collection-behaviour matrix against a fullscreen app
        // with somebody watching the screen, and its answer replaces this one (RUNBOOK).
        #expect(BarPanelConfiguration.bar.level == .popUpMenu)
    }

    // MARK: Strings (PRD §7.12)

    @Test func everyStringTheBarSaysIsInTheCatalogue() throws {
        let bundle = BarStrings.bundle
        for key in BarStrings.all {
            let missing = "\u{1}missing\u{1}"
            let value = bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(value != missing, "\(key) has no entry in Localizable.strings")
        }
    }

    @Test func nothingTheBarSaysIsWrittenInPlace() {
        #expect(!BarStrings.barLabel.isEmpty)
        #expect(!BarStrings.barAppeared.isEmpty)
        #expect(BarStrings.feedbackCopied == "Copied")
    }

    @Test func aDisabledButtonSaysWhyInItsTooltipAndToVoiceOver() {
        let button = item("replace", "Replace Selection", enabled: false, why: "this app will not take text")

        #expect(button.tooltip.contains("Replace Selection"))
        #expect(button.tooltip.contains("will not take text"))
        #expect(item("copy", "Copy").tooltip == "Copy")
    }

    // MARK: Measuring (BAR-6)

    @Test func anIconButtonIsSquareInsideTheBarsHeight() {
        let widths = BarItemMeasurer().widths(
            for: BarContent(items: [item("copy")]),
            metrics: .standard
        )

        #expect(widths.count == 1)
        #expect(widths[0] > 0)
        #expect(widths[0] <= BarMetrics.standard.height)
    }

    @Test func aTextButtonIsAsWideAsItsWords() {
        let short = BarItem(id: BarItemID("a"), name: "A", display: .text("A"))
        let long = BarItem(id: BarItemID("b"), name: "B", display: .text("A much longer label"))
        let widths = BarItemMeasurer().widths(for: BarContent(items: [short, long]), metrics: .standard)

        #expect(widths[1] > widths[0])
    }
}
