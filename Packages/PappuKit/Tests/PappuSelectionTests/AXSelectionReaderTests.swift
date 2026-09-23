import CoreGraphics
import PappuAX
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.apple.TextEdit")
private let selection = AXTextRange(location: 12, length: 5)
private let caret = AXTextRange(location: 12, length: 0)
private let rect = CGRect(x: 100, y: 200, width: 80, height: 18)

/// The read stage's budget on the Accessibility path (PRD §11.1), in seconds, as AX takes it.
private let readTimeout = Float(0.070)

private func reader(_ world: FakeAXWorld) async -> AXSelectionReader {
    await AXSelectionReader(world: world)
}

/// A focused element with a selection in it, which is the ordinary case for strategies 1 and 3.
private func worldWithSelection(
    text: String? = "hello",
    range: AXTextRange? = selection,
    bounds: CGRect? = rect
) -> FakeAXWorld {
    let world = FakeAXWorld()
    let node = FakeAXWorld.Node(role: "AXTextArea", selectedRange: range, selectedText: text)
    if let bounds, let range { node.setBounds(bounds, for: range) }
    world.setFocused(node, in: target.pid)
    return world
}

/// ACT-9 strategies 1 and 3: the Accessibility reads, and what each of them does and does not ask an
/// app for (architecture §4.5).
@Suite struct AXSelectionReaderTests {

    // MARK: Strategy 1

    @Test func aSelectionComesBackWithItsRangeAndItsRectangle() async {
        let read = await reader(worldWithSelection()).read(in: target)

        #expect(read.finding == .text)
        #expect(read.text == "hello")
        #expect(read.range == selection)
        #expect(read.bounds == rect)
        #expect(read.fault == nil)
    }

    /// BAR-3: an app that will not say where its selection is has not failed, it has left the bar to
    /// the pointer.
    @Test func noRectangleIsNotAFailure() async {
        let read = await reader(worldWithSelection(bounds: nil)).read(in: target)

        #expect(read.finding == .text)
        #expect(read.bounds == nil)
    }

    /// The null, infinite and empty rectangles apps answer with for a selection scrolled out of view.
    /// A bar in the corner of the screen is worse than a bar at the pointer.
    @Test func aDegenerateRectangleIsNoRectangle() async {
        for degenerate in [CGRect.null, .infinite, CGRect(x: 10, y: 10, width: 0, height: 18)] {
            let read = await reader(worldWithSelection(bounds: degenerate)).read(in: target)

            #expect(read.finding == .text)
            #expect(read.bounds == nil)
        }
    }

    /// ACT-3, and the point of it: an empty `AXSelectedTextRange` is a caret by definition, so the
    /// attribute that holds the user's text is never asked for. A read not made is the strongest
    /// privacy claim there is.
    @Test func aCaretIsAnsweredWithoutReadingAnyText() async {
        let world = worldWithSelection(text: "a whole line of somebody's document", range: caret)
        let read = await reader(world).read(in: target)

        #expect(read.finding == .caret)
        #expect(read.range == caret)
        #expect(read.text == nil)
        #expect(!world.asked.contains(.selectedText))
    }

    /// ACT-10e: the length is kept so strategy 5 has something to check the pasteboard against.
    @Test func aRangeWithNoTextKeepsTheRange() async {
        let read = await reader(worldWithSelection(text: nil)).read(in: target)

        #expect(read.finding == .nothing)
        #expect(read.range == selection)
        #expect(read.fault == .unsupported)
    }

    @Test func anEmptyStringIsNothingAndNotText() async {
        let read = await reader(worldWithSelection(text: "")).read(in: target)

        #expect(read.finding == .nothing)
        #expect(read.text == nil)
    }

    /// Text without a range is read all the same: several apps answer `AXSelectedText` and refuse
    /// `AXSelectedTextRange`, and the text is what the bar is for.
    @Test func textWithoutARangeIsStillText() async {
        let read = await reader(worldWithSelection(range: nil)).read(in: target)

        #expect(read.finding == .text)
        #expect(read.text == "hello")
        #expect(read.range == nil)
        #expect(read.bounds == nil)
    }

    /// Not `nothing`: an app with no focused element is one this strategy cannot run against, which is
    /// what lets the chain go on to the next.
    @Test func noFocusedElementIsUnavailable() async {
        let read = await reader(FakeAXWorld()).read(in: target)

        #expect(read.finding == .unavailable)
        #expect(read.fault == .unsupported)
    }

    @Test func aRefusedGrantIsUnavailableAndSaysWhy() async {
        let world = worldWithSelection()
        world.failApplication(target.pid, with: .notPermitted)
        let read = await reader(world).read(in: target)

        #expect(read.finding == .unavailable)
        #expect(read.fault == .notPermitted)
    }

    // MARK: The timeout (PRD §11.1)

    @Test func everyCallIsBoundedByTheReadStagesBudget() async {
        let world = worldWithSelection()
        _ = await reader(world).read(in: target)

        #expect(!world.timeouts.isEmpty)
        #expect(world.timeouts.allSatisfy { $0 == readTimeout })
    }

    /// AX reads zero as "use the global default", which hands a wedged app the AX queue for seconds.
    /// A chain whose earlier strategies have spent the budget must still be bounded.
    @Test func anExhaustedBudgetIsAFloorAndNeverZero() async {
        let world = worldWithSelection()
        _ = await reader(world).read(in: target, timeout: .zero)

        #expect(!world.timeouts.isEmpty)
        #expect(world.timeouts.allSatisfy { $0 > 0 && $0 <= 0.001 })
    }

    // MARK: Strategy 3 (architecture §4.5)

    @Test func enablingWritesTheSpellingTheAppWants() async {
        for (kind, expected) in [
            (AXTreeEnabling.manualAccessibility, [AXTreeSwitch.manualAccessibility]),
            (.enhancedUserInterface, [.enhancedUserInterface]),
            (.both, [.manualAccessibility, .enhancedUserInterface]),
        ] {
            let world = worldWithSelection()
            let read = await reader(world).read(enabling: kind, in: target)

            #expect(read.finding == .text)
            #expect(world.treeSwitches.map(\.which) == expected)
            #expect(world.treeSwitches.allSatisfy { $0.on && $0.pid == target.pid })
        }
    }

    /// Enable-and-hold: the switch is a message to another process about itself, and sending it before
    /// every read is both slower and ruder.
    @Test func theSwitchIsWrittenOncePerProcessAndNotOncePerRead() async {
        let world = worldWithSelection()
        let reader = await reader(world)
        for _ in 0..<3 { _ = await reader.read(enabling: .manualAccessibility, in: target) }

        #expect(world.treeSwitches.count == 1)
        #expect(await reader.isTreeSwitchedOn(for: target.pid))
    }

    /// An app that answers `.unsupported` may have had its tree on all along — a screen reader, the
    /// user's own setting — so the fault is carried into the trace rather than turned into a refusal.
    @Test func aFaultedSwitchStillReads() async {
        let world = worldWithSelection()
        world.failTreeSwitch(target.pid, with: .unsupported)
        let reader = await reader(world)
        let read = await reader.read(enabling: .both, in: target)

        #expect(read.finding == .text)
        #expect(world.treeSwitches.isEmpty)
        // Nothing was taken, so nothing is remembered and the next attempt asks again.
        #expect(await !reader.isTreeSwitchedOn(for: target.pid))
    }

    /// The fault rides along on a read that found nothing, which is what the inspector needs to tell
    /// "this app has no tree" from "this app has no selection" (DIA-2).
    @Test func aFaultedSwitchIsCarriedIntoTheTrace() async {
        let world = FakeAXWorld()
        world.failTreeSwitch(target.pid, with: .notPermitted)
        let read = await reader(world).read(enabling: .manualAccessibility, in: target)

        #expect(read.finding == .unavailable)
        #expect(read.fault == .notPermitted)
    }

    /// Nothing we did to another program outlives us.
    @Test func releaseSwitchesTheTreeBackOffAndForgetsIt() async {
        let world = worldWithSelection()
        let reader = await reader(world)
        _ = await reader.read(enabling: .both, in: target)
        #expect(await reader.release(target.pid))

        #expect(world.treeSwitches.filter { !$0.on }.map(\.which) == [.manualAccessibility, .enhancedUserInterface])
        #expect(await !reader.isTreeSwitchedOn(for: target.pid))
        // And a second release has nothing to do.
        #expect(await !reader.release(target.pid))
    }

    @Test func releaseAllPutsEveryProcessBack() async {
        let world = worldWithSelection()
        let other = TargetApp(pid: 777, bundleID: "com.microsoft.VSCode")
        world.setFocused(FakeAXWorld.Node(role: "AXTextArea", selectedRange: selection, selectedText: "hi"), in: other.pid)
        let reader = await reader(world)
        _ = await reader.read(enabling: .manualAccessibility, in: target)
        _ = await reader.read(enabling: .manualAccessibility, in: other)
        await reader.releaseAll()

        #expect(world.treeSwitches.filter { !$0.on }.count == 2)
        #expect(await !reader.isTreeSwitchedOn(for: target.pid))
        #expect(await !reader.isTreeSwitchedOn(for: other.pid))
    }
}
