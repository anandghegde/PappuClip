import CoreGraphics
import Foundation
import PappuAX
import PappuCore
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.apple.Safari")
private let elsewhere = TargetApp(pid: 909, bundleID: "com.apple.Terminal")
private let selected = "a sentence the user picked"
/// Where the caret sat before the gesture, and where the selection ended up after it.
private let caret = AXTextRange(location: 4, length: 0)
private let afterGesture = AXTextRange(location: 10, length: 26)
private let pressed = CGPoint(x: 400, y: 260)

private let policy = DetectionPolicy(
    strategies: [.ax, .webkitMarkers],
    autoAppear: true,
    autoSyntheticCopy: false,
    hotkeySyntheticCopy: true,
    quiescence: true
)

private let readText = SelectionRead(
    outcome: .text,
    text: selected,
    range: afterGesture,
    bounds: CGRect(x: 10, y: 20, width: 80, height: 14),
    strategy: .ax
)

private func event(
    _ kind: PointerEvent.Kind,
    x: Double,
    y: Double,
    ms: UInt64,
    clicks: Int = 1,
    _ modifiers: PointerEvent.Modifiers = [],
    window: Int = 7
) -> PointerEvent {
    PointerEvent(
        kind: kind,
        location: CGPoint(x: x, y: y),
        modifiers: modifiers,
        clickCount: clicks,
        timestampNs: ms * 1_000_000,
        windowNumber: window
    )
}

/// The two things the coordinator asks the system about rather than is handed: which app is in front,
/// and whether secure input is on. Both can change between the mouse going down and coming up, which is
/// the whole reason the coordinator asks twice.
private final class Surroundings: Sendable {
    private struct State {
        var frontmost: TargetApp?
        var secureInput = false
    }

    private let state = Mutex(State())

    init(frontmost: TargetApp?) {
        state.withLock { $0.frontmost = frontmost }
    }

    var frontmost: TargetApp? {
        get { state.withLock { $0.frontmost } }
        set { state.withLock { $0.frontmost = newValue } }
    }

    var secureInputIsActive: Bool {
        get { state.withLock { $0.secureInput } }
        set { state.withLock { $0.secureInput = newValue } }
    }
}

/// Everything the coordinator talks to, all of it a fake: the Accessibility tree, the strategy chain
/// that does not exist yet, the bar that does not exist yet, the long-press timer and the clock.
private struct Harness: Sendable {
    let world: FakeAXWorld
    let reader: FakeSelectionReader
    let presenter: FakeBarPresenter
    let timing: FakeActivationTiming
    let time: ManualTimeSource
    let surroundings: Surroundings
    let coordinator: ActivationCoordinator

    /// Press, drag well past the slop, release: the gesture of ACT-1, and the one ACT-2 says is not over
    /// until the button comes up.
    func dragSelect() async {
        await coordinator.handle(.pointer(event(.down, x: pressed.x, y: pressed.y, ms: 0)))
        await coordinator.handle(.pointer(event(.dragged, x: 470, y: 300, ms: 40)))
        await coordinator.handle(.pointer(event(.up, x: 520, y: 320, ms: 220)))
        await settle()
    }

    /// A press held until macOS's timer would have fired (ACT-3).
    func longPress() async {
        await coordinator.handle(.pointer(event(.down, x: pressed.x, y: pressed.y, ms: 0)))
        timing.fire()
        await settle()
    }

    /// The long-press timer and the outside watchers reach the actor on tasks of their own, as they do in
    /// the app; a few yields let whatever is already enqueued arrive before we ask what is in flight.
    func settle() async {
        for _ in 0..<8 { await Task.yield() }
        await coordinator.settle()
    }
}

private func harness(
    rules: PrivacyRules = PrivacyRules(),
    policies: DetectionPolicies = DetectionPolicies(default: policy),
    read: SelectionRead = readText,
    focused: FakeAXWorld.Node? = FakeAXWorld.Node(role: "AXTextArea", selectedRange: caret),
    underPointer: FakeAXWorld.Node? = FakeAXWorld.Node(role: "AXTextArea"),
    frontmost: TargetApp? = target,
    traceCapacity: Int = 64
) async -> Harness {
    let world = FakeAXWorld()
    world.setFocused(focused, in: target.pid)
    world.setUnderPointer(underPointer, at: pressed)
    let reader = FakeSelectionReader(read)
    let presenter = FakeBarPresenter()
    let timing = FakeActivationTiming()
    let time = ManualTimeSource()
    let surroundings = Surroundings(frontmost: frontmost)
    let coordinator = await ActivationCoordinator(
        gate: PrivacyGate(rules),
        policies: DetectionPolicyStore(policies),
        probe: AXFocusProbe(world: world),
        reader: reader,
        presenter: presenter,
        frontmost: { surroundings.frontmost },
        secureInputIsActive: { surroundings.secureInputIsActive },
        timing: timing,
        now: time.reader,
        configuration: ActivationCoordinator.Configuration(traceCapacity: traceCapacity)
    )
    return Harness(
        world: world,
        reader: reader,
        presenter: presenter,
        timing: timing,
        time: time,
        surroundings: surroundings,
        coordinator: coordinator
    )
}

/// The activation path end to end, with every seam faked. What these tests are really about is order:
/// which gestures reach a read, which reads reach a bar, and what a later event does to an attempt that
/// has not finished yet.
@Suite struct ActivationCoordinatorTests {
    // MARK: Which gestures reach a bar (ACT-1, ACT-2, ACT-3, ACT-7)

    @Test func aDragThatSelectsTextShowsTheBar() async {
        let harness = await harness()
        await harness.dragSelect()

        #expect(harness.presenter.last?.text == selected)
        #expect(harness.presenter.last?.verdict == .selection)
        #expect(harness.presenter.last?.route == .automatic)
        // BAR-3 wants to know which way the drag went, and it went downwards.
        #expect(harness.presenter.last?.dragDirection == .downwards)
        #expect(await harness.coordinator.lastAttempt?.showedBar == true)
        #expect(await harness.coordinator.lastAttempt?.strategy == .ax)
    }

    @Test func noBarAppearsWhileTheButtonIsStillDown() async {
        let harness = await harness()
        await harness.coordinator.handle(.pointer(event(.down, x: pressed.x, y: pressed.y, ms: 0)))
        await harness.coordinator.handle(.pointer(event(.dragged, x: 470, y: 300, ms: 40)))
        await harness.settle()

        #expect(harness.reader.wasAsked == false)
        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.attempts.isEmpty)
    }

    @Test func aLongPressInAFieldShowsABarWithNoSelectionSoPasteIsReachable() async {
        let harness = await harness(read: SelectionRead(outcome: .caretOnly, range: caret, strategy: .ax))
        await harness.longPress()

        #expect(harness.presenter.last?.verdict == .caret)
        #expect(harness.presenter.last?.text == nil)
    }

    @Test func aLongPressOnAParagraphOneCannotTypeIntoShowsNothing() async {
        let harness = await harness(
            read: SelectionRead(outcome: .caretOnly, strategy: .ax),
            focused: FakeAXWorld.Node(role: "AXStaticText"),
            underPointer: FakeAXWorld.Node(role: "AXStaticText")
        )
        await harness.longPress()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .nothingTextual)
    }

    @Test func holdingCommandThroughAGestureReadsNothingAtAll() async {
        let harness = await harness()
        await harness.coordinator.handle(.pointer(event(.down, x: pressed.x, y: pressed.y, ms: 0, .command)))
        await harness.coordinator.handle(.pointer(event(.dragged, x: 470, y: 300, ms: 40, .command)))
        await harness.coordinator.handle(.pointer(event(.up, x: 520, y: 320, ms: 220, .command)))
        await harness.settle()

        #expect(harness.reader.wasAsked == false)
        #expect(harness.presenter.showedBar == false)
        // Recorded all the same, so that "why didn't it appear?" has an answer (DIA-2).
        #expect(await harness.coordinator.lastAttempt?.verdict == .suppressed)
    }

    // MARK: Several signals, none of them alone (ACT-14)

    @Test func aSelectionThatIsWhereItWasBeforeTheGestureShowsNoBar() async {
        let harness = await harness(
            read: SelectionRead(outcome: .text, text: selected, range: afterGesture, strategy: .ax),
            focused: FakeAXWorld.Node(role: "AXTextArea", selectedRange: afterGesture)
        )
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .unchangedRange)
    }

    @Test func aGestureThatSelectedNothingNeverShowsABar() async {
        let harness = await harness(read: .nothing)
        await harness.dragSelect()

        #expect(harness.reader.wasAsked == true)
        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .noText)
    }

    @Test func anAppNoStrategyCanReadIsCalledUnreadableRatherThanEmpty() async {
        let harness = await harness(read: SelectionRead(outcome: .refused))
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .unreadable)
    }

    // MARK: The routes with no gesture (ACT-5)

    @Test func theShortcutShowsTheBarWithNoGestureAtAll() async {
        let harness = await harness()
        await harness.coordinator.activate(route: .hotkey)
        await harness.settle()

        #expect(harness.presenter.last?.route == .hotkey)
        #expect(harness.presenter.last?.verdict == .selection)
        #expect(await harness.coordinator.lastAttempt?.gesture == nil)
        // The shortcut may fall through to a synthetic ⌘C; the automatic route in this app may not.
        #expect(harness.reader.calls.first?.chain == [.ax, .webkitMarkers, .syntheticCopy])
    }

    @Test func theShortcutShowsTheSelectionTheUserAlreadyHad() async {
        // The automatic route withholds this one, because nothing about it changed; a route the user
        // asked for does not, because they asked about whatever is selected now.
        let harness = await harness(
            read: SelectionRead(outcome: .text, text: selected, range: afterGesture, strategy: .ax),
            focused: FakeAXWorld.Node(role: "AXTextArea", selectedRange: afterGesture)
        )
        await harness.coordinator.activate(route: .hotkey)
        await harness.settle()

        #expect(harness.presenter.last?.verdict == .selection)
    }

    // MARK: What is never read (ACT-12, ACT-18, ACT-11a)

    @Test func secureInputStopsTheAttemptBeforeAnyStrategyRuns() async {
        let harness = await harness()
        harness.surroundings.secureInputIsActive = true
        await harness.dragSelect()

        #expect(harness.reader.wasAsked == false)
        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.denial == .secureInputActive)
    }

    @Test func aSecureFieldStopsTheAttemptOnTheRoleTheProbeRead() async {
        let harness = await harness(
            focused: FakeAXWorld.Node(role: "AXTextField", subrole: "AXSecureTextField")
        )
        await harness.dragSelect()

        #expect(harness.reader.wasAsked == false)
        #expect(await harness.coordinator.lastAttempt?.denial == .secureTextField)
    }

    @Test func aPausedAppIsNeverRead() async {
        let harness = await harness(rules: PrivacyRules(pause: .untilResumed))
        await harness.dragSelect()

        #expect(harness.reader.wasAsked == false)
        #expect(await harness.coordinator.lastAttempt?.denial == .pausedUntilResumed)
    }

    @Test func anAppWhosePolicyForbidsTheAutomaticBarIsReadOnlyWhenAsked() async {
        let quiet = DetectionPolicy(
            strategies: [.ax],
            autoAppear: false,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: true,
            quiescence: false
        )
        let harness = await harness(policies: DetectionPolicies(default: quiet))
        await harness.dragSelect()

        #expect(harness.reader.wasAsked == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .policyDisallows)

        await harness.coordinator.activate(route: .hotkey)
        await harness.settle()

        #expect(harness.reader.wasAsked == true)
        #expect(harness.presenter.showedBar == true)
    }

    @Test func theReadIsGivenThePermitTheGateMintedAndTheChainThePolicyAllows() async {
        let harness = await harness()
        await harness.dragSelect()

        let call = harness.reader.calls.first
        #expect(call?.route == .automatic)
        #expect(call?.target == target)
        #expect(call?.scope == .fullText)
        #expect(call?.chain == [.ax, .webkitMarkers])
    }

    // MARK: A late answer is not an answer (ACT-16)

    @Test func aNewerGestureRetiresTheOneStillReading() async {
        let harness = await harness()
        harness.reader.interrupt {
            // A second selection, made while the first read is still out.
            await harness.coordinator.handle(.pointer(event(.down, x: 600, y: 300, ms: 400)))
            await harness.coordinator.handle(.pointer(event(.dragged, x: 650, y: 330, ms: 440)))
            await harness.coordinator.handle(.pointer(event(.up, x: 700, y: 360, ms: 600)))
        }
        await harness.dragSelect()
        await harness.settle()

        let attempts = await harness.coordinator.attempts
        #expect(attempts.count == 2)
        #expect(attempts.first?.showedBar == false)
        // The press retires it before the gesture it belongs to is even over: pressing somewhere else is
        // already the user saying the old selection is not what they are looking at.
        #expect(attempts.first?.invalidation == .newerInput)
        // One bar, for the gesture the user made last.
        #expect(harness.presenter.shown.count == 1)
        #expect(harness.presenter.last?.attempt == attempts.last?.attempt)
    }

    @Test func aShortcutWhileAGestureIsStillReadingRetiresTheGesture() async {
        // The same rule with no pointer in it: the shortcut starts an attempt of its own, and the one
        // already out is retired by the newer attempt rather than by any event.
        let harness = await harness()
        harness.reader.interrupt {
            await harness.coordinator.activate(route: .hotkey)
        }
        await harness.dragSelect()
        await harness.settle()

        let attempts = await harness.coordinator.attempts
        #expect(attempts.count == 2)
        #expect(attempts.first?.invalidation == .newerAttempt)
        #expect(harness.presenter.shown.map(\.route) == [.hotkey])
    }

    @Test func aFocusChangeWhileReadingWithholdsTheBar() async {
        let harness = await harness()
        harness.reader.interrupt {
            await harness.coordinator.invalidate(.focusChanged)
        }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.invalidation == .focusChanged)
        // The text had already come back; what is kept of it is how much, never what.
        #expect(await harness.coordinator.lastAttempt?.characters == selected.count)
    }

    @Test func anotherApplicationComingForwardWhileReadingWithholdsTheBar() async {
        let harness = await harness()
        harness.reader.interrupt {
            await harness.coordinator.invalidate(.applicationActivated)
        }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.invalidation == .applicationActivated)
    }

    @Test func aReadThatOverrunsTheHardCutoffShowsNothing() async {
        let harness = await harness()
        harness.reader.interrupt {
            harness.time.advance(by: .milliseconds(800))
        }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.invalidation == .hardCutoff)
        #expect(await harness.coordinator.lastAttempt?.verdict == .outOfBudget)
    }

    @Test func aTapInterruptionRetiresWhateverWasInFlight() async {
        let harness = await harness()
        harness.reader.interrupt {
            await harness.coordinator.handle(.interrupted)
        }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.invalidation == .tapInterrupted)
    }

    @Test func aBarOnlyAppearsForTheAttemptThatIsStillCurrent() async {
        let harness = await harness()
        await harness.dragSelect()

        let attempt = await harness.coordinator.lastAttempt?.attempt
        #expect(harness.presenter.last?.attempt == attempt)
        #expect(await harness.coordinator.currentAttempt == attempt)
        // The permit carries what is left of the 700 ms, so the bar knows its own budget (ACT-16c).
        #expect(harness.presenter.last?.remaining == .milliseconds(700))
    }

    // MARK: The trace (DIA-2)

    @Test func theTraceHoldsCodesAndCountsAndNeverTheSelection() async {
        let harness = await harness()
        await harness.dragSelect()

        let record = await harness.coordinator.lastAttempt
        #expect(record?.bundleID == target.bundleID)
        #expect(record?.outcome == .text)
        #expect(record?.characters == selected.count)
        // Every field the record has, written out. The selection is in none of them.
        #expect(!String(describing: record).contains(selected))
    }

    @Test func theTraceKeepsOnlyItsLastFewAttempts() async {
        let harness = await harness(traceCapacity: 3)
        for _ in 0..<5 {
            await harness.coordinator.activate(route: .hotkey)
            await harness.settle()
        }

        let attempts = await harness.coordinator.attempts
        #expect(attempts.count == 3)
        #expect(attempts.map(\.attempt) == attempts.map(\.attempt).sorted())
        // All five happened; only the last three are remembered.
        #expect(harness.presenter.shown.count == 5)
        #expect(attempts.last?.attempt == harness.presenter.shown.last?.attempt)
    }

    @Test func anAttemptInAnAppThatIsNoLongerThereIsRecordedAndDropped() async {
        let harness = await harness(frontmost: nil)
        await harness.coordinator.activate(route: .hotkey)
        await harness.settle()

        #expect(harness.reader.wasAsked == false)
        #expect(await harness.coordinator.lastAttempt?.verdict == .unreadable)
    }

    @Test func anAppThatWouldNotAnswerTheProbeIsRecordedAsAFaultAndReadAnyway() async {
        // ACT-12's asymmetry: no Accessibility tree is not a secure field, so the chain still runs. The
        // fault is kept so that the inspector can say why the AX strategy came back empty.
        let harness = await harness(frontmost: elsewhere)
        harness.world.failApplication(elsewhere.pid, with: .notPermitted)
        await harness.coordinator.activate(route: .hotkey)
        await harness.settle()

        #expect(await harness.coordinator.lastAttempt?.fault == .notPermitted)
        #expect(harness.reader.wasAsked == true)
    }
}
