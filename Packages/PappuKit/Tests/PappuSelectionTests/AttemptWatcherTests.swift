import CoreGraphics
import Foundation
import PappuAX
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.apple.Safari")
private let elsewhere = TargetApp(pid: 909, bundleID: "com.apple.Terminal")
private let selected = "a sentence the user picked"
private let caret = AXTextRange(location: 4, length: 0)
private let afterGesture = AXTextRange(location: 10, length: 26)
private let pressed = CGPoint(x: 400, y: 260)

private let readText = SelectionRead(
    outcome: .text,
    text: selected,
    range: afterGesture,
    bounds: CGRect(x: 10, y: 20, width: 80, height: 14),
    strategy: .ax
)

private func event(_ kind: PointerEvent.Kind, x: Double, y: Double, ms: UInt64) -> PointerEvent {
    PointerEvent(
        kind: kind,
        location: CGPoint(x: x, y: y),
        modifiers: [],
        clickCount: 1,
        timestampNs: ms * 1_000_000,
        windowNumber: 7
    )
}

/// The watcher, the two things it listens to, and the coordinator it reports to. The coordinator is
/// built for every test and used by the ones at the end, where what matters is that a notice raised out
/// here retires an attempt in there.
private struct Harness: Sendable {
    let observer: FakeAXObserver
    let activations: FakeApplicationActivations
    let watcher: AttemptWatcher
    let reader: FakeSelectionReader
    let presenter: FakeBarPresenter
    let coordinator: ActivationCoordinator

    func dragSelect() async {
        await coordinator.handle(.pointer(event(.down, x: pressed.x, y: pressed.y, ms: 0)))
        await coordinator.handle(.pointer(event(.dragged, x: 470, y: 300, ms: 40)))
        await coordinator.handle(.pointer(event(.up, x: 520, y: 320, ms: 220)))
        await settle()
    }

    func settle() async {
        for _ in 0..<8 { await Task.yield() }
        await coordinator.settle()
    }

    /// The notice the app's own pump would have taken off the stream by now. Only called where one is
    /// expected: the negative cases count `retirements` instead, which is raised in the same breath as
    /// the notice and does not have to be waited for.
    func notice() async -> AttemptNotice? {
        var notices = watcher.notices.makeAsyncIterator()
        return await notices.next()
    }
}

private func harness(observer: FakeAXObserver = FakeAXObserver()) async -> Harness {
    let world = FakeAXWorld()
    world.setFocused(FakeAXWorld.Node(role: "AXTextArea", selectedRange: caret), in: target.pid)
    world.setUnderPointer(FakeAXWorld.Node(role: "AXTextArea"), at: pressed)
    let activations = FakeApplicationActivations()
    let watcher = AttemptWatcher(observer: observer, activations: activations)
    watcher.start()
    let reader = FakeSelectionReader(readText)
    let presenter = FakeBarPresenter()
    let coordinator = await ActivationCoordinator(
        gate: PrivacyGate(PrivacyRules()),
        policies: DetectionPolicyStore(DetectionPolicies(default: DetectionPolicy(
            strategies: [.ax, .webkitMarkers],
            autoAppear: true,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: true,
            quiescence: true
        ))),
        probe: AXFocusProbe(world: world),
        reader: reader,
        presenter: presenter,
        watcher: watcher,
        frontmost: { target },
        secureInputIsActive: { false },
        timing: FakeActivationTiming(),
        now: ManualTimeSource().reader
    )
    return Harness(
        observer: observer,
        activations: activations,
        watcher: watcher,
        reader: reader,
        presenter: presenter,
        coordinator: coordinator
    )
}

private let first = AttemptID(rawValue: 1)
private let second = AttemptID(rawValue: 2)

/// The watchers of ACT-16a: the `AXObserver` on the app an attempt is about, and the workspace's
/// activation notices. What these tests are about is which notices mean the user has moved on and which
/// are the echo of the gesture that started the attempt in the first place.
@Suite struct AttemptWatcherTests {
    // MARK: Another app came forward

    @Test func anAppComingForwardWhileAnAttemptIsArmedRetiresIt() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.activations.send(elsewhere)

        #expect(await harness.notice() == AttemptNotice(attempt: first, reason: .applicationActivated))
        #expect(harness.watcher.armedAttempt == nil)
    }

    /// Clicking into an app that was not in front brings it forward, and that notice can arrive after the
    /// gesture is over. The app it names is the one the attempt is about, which is how it is told apart
    /// from the user going somewhere else.
    @Test func theAppTheAttemptIsAboutComingForwardRetiresNothing() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.activations.send(target)

        #expect(harness.watcher.retirements.total == 0)
        #expect(harness.watcher.armedAttempt == first)
    }

    @Test func anAppComingForwardWithNoAttemptArmedRetiresNothing() async {
        let harness = await harness()
        harness.activations.send(elsewhere)

        #expect(harness.watcher.retirements.total == 0)
    }

    // MARK: The selection moved

    /// The tap sees mouse-up before the app does, so the app posts its selection notice after the attempt
    /// has begun. Taken at face value it would retire every drag the user makes.
    @Test func aSelectionThatMovesBeforeTheReadIsBackRetiresNothing() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.observer.send(.selectedTextChanged)

        #expect(harness.watcher.retirements.total == 0)
        #expect(harness.watcher.armedAttempt == first)
    }

    @Test func aSelectionThatMovesAfterTheReadIsBackRetiresTheAttempt() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.watcher.readReturned(for: first)
        harness.observer.send(.selectedTextChanged)

        #expect(await harness.notice() == AttemptNotice(attempt: first, reason: .focusChanged))
    }

    @Test func aFocusChangeAfterTheReadIsBackRetiresTheAttempt() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.watcher.readReturned(for: first)
        harness.observer.send(.focusedElementChanged)

        #expect(await harness.notice() == AttemptNotice(attempt: first, reason: .focusChanged))
    }

    /// One keystroke can make an app post several notices. The attempt is retired once and the coordinator
    /// hears about it once.
    @Test func onlyTheFirstNoticeRetiresAnAttempt() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.watcher.readReturned(for: first)
        harness.observer.send(.selectedTextChanged)
        harness.observer.send(.focusedElementChanged)

        #expect(harness.watcher.retirements.total == 1)
        #expect(harness.watcher.retirements.counts[.focusChanged] == 1)
    }

    // MARK: Which attempt a notice is about

    @Test func aNoticeAfterTheAttemptIsOverRetiresNothing() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        harness.watcher.readReturned(for: first)
        harness.watcher.disarm(first)
        harness.observer.send(.selectedTextChanged)
        harness.activations.send(elsewhere)

        #expect(harness.watcher.retirements.total == 0)
    }

    /// An attempt that a newer one replaced finishes some time later and disarms itself. The newer one is
    /// the armed one by then, and has to stay armed.
    @Test func disarmingAnAttemptANewerOneReplacedLeavesTheNewerOneArmed() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        await harness.watcher.arm(second, in: target)
        harness.watcher.disarm(first)
        harness.activations.send(elsewhere)

        #expect(await harness.notice() == AttemptNotice(attempt: second, reason: .applicationActivated))
    }

    /// The read of an attempt that is no longer the armed one comes back all the same, and says so.
    @Test func aReadThatComesBackForAReplacedAttemptDoesNotArmTheNewerOne() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)
        await harness.watcher.arm(second, in: target)
        harness.watcher.readReturned(for: first)
        harness.observer.send(.selectedTextChanged)

        #expect(harness.watcher.retirements.total == 0)
        #expect(harness.watcher.armedAttempt == second)
    }

    // MARK: What it asks an app for

    /// Every mouse-down in the same app prepares again, and the app is asked once. The registration is an
    /// Accessibility call and every one of them blocks on the app it is made to.
    @Test func theAppIsRegisteredWithOnceHoweverManyTimesTheMouseGoesDown() async {
        let harness = await harness()
        await harness.watcher.prepare(for: target)
        await harness.watcher.prepare(for: target)
        await harness.watcher.arm(first, in: target)

        #expect(harness.observer.registrations.count == 1)
        #expect(harness.watcher.observedApplication == target.pid)
    }

    @Test func aGestureInAnotherAppMovesTheRegistration() async {
        let harness = await harness()
        await harness.watcher.prepare(for: target)
        await harness.watcher.prepare(for: elsewhere)

        #expect(harness.observer.registrations.map(\.pid) == [target.pid, elsewhere.pid])
        #expect(harness.watcher.observedApplication == elsewhere.pid)
    }

    /// The shortcut has no mouse-down to prepare on, so it pays for the registration itself (ACT-5).
    @Test func theRouteWithNoMouseDownRegistersWhenItArms() async {
        let harness = await harness()
        await harness.watcher.arm(first, in: target)

        #expect(harness.observer.registrations.count == 1)
        #expect(harness.watcher.armedAttempt == first)
    }

    /// The closed list of `AXNotification`, asserted rather than remembered: both of these say that
    /// something moved and neither carries what it moved to, and there is nothing else here that could
    /// ask an app for a value (ACT-12).
    @Test func theOnlyThingsItAsksAnAppToTellItAreTheTwoThatCarryNoText() async {
        let harness = await harness()
        await harness.watcher.prepare(for: target)

        #expect(AXNotification.allCases == [.focusedElementChanged, .selectedTextChanged])
        #expect(harness.observer.registrations.first?.notifications == AXNotification.allCases)
    }

    /// An app that will not be observed is a fact for the inspector and nothing more: the attempt runs
    /// unwatched, as it does in every app with no Accessibility tree at all.
    @Test func anAppThatWillNotBeWatchedIsRecordedAndItsAttemptsRunUnwatched() async {
        let harness = await harness(observer: FakeAXObserver(refusing: .notPermitted))
        await harness.watcher.arm(first, in: target)
        harness.observer.send(.selectedTextChanged)

        #expect(harness.watcher.fault == .notPermitted)
        #expect(harness.watcher.observedApplication == nil)
        #expect(harness.watcher.retirements.total == 0)

        // Nothing is remembered about the refusal, so the next attempt in that app asks again: the grant
        // can arrive while the app is running (ONB-4).
        await harness.watcher.arm(second, in: target)
        #expect(harness.observer.registrations.count == 2)
    }

    @Test func stoppingTakesBothWatchersDownWithIt() async {
        let harness = await harness()
        await harness.watcher.prepare(for: target)
        await harness.watcher.stop()

        #expect(harness.observer.isObserving == false)
        #expect(harness.activations.isObserving == false)
        #expect(harness.watcher.observedApplication == nil)
    }

    // MARK: Through the coordinator

    @Test func theCoordinatorRegistersWithTheAppItIsReadingAndDisarmsWhenItIsDone() async {
        let harness = await harness()
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == true)
        #expect(harness.observer.registrations.map(\.pid) == [target.pid])
        #expect(harness.watcher.armedAttempt == nil)
    }

    /// The regression the whole arrangement exists for: the app posts the notice for the user's own drag
    /// while PappuClip is reading it, and the bar still appears.
    @Test func aGesturesOwnSelectionNoticeDoesNotStopItsOwnBar() async {
        let harness = await harness()
        harness.reader.interrupt { harness.observer.send(.selectedTextChanged) }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == true)
        #expect(harness.watcher.retirements.total == 0)
    }

    /// Another app coming forward while the read is out, all the way through: the watcher raises the
    /// notice, the coordinator is told, and the attempt it was raised for keeps its bar to itself.
    @Test func aNoticeFromTheWatchersWithholdsTheBarOfTheAttemptItWasRaisedFor() async {
        let harness = await harness()
        harness.reader.interrupt {
            harness.activations.send(elsewhere)
            guard let notice = await harness.notice() else { return }
            await harness.coordinator.invalidate(notice.reason, of: notice.attempt)
        }
        await harness.dragSelect()

        #expect(harness.presenter.showedBar == false)
        #expect(await harness.coordinator.lastAttempt?.invalidation == .applicationActivated)
    }

    /// A notice takes a hop to reach the coordinator, and the attempt it was raised for may be over by
    /// then. It retires that attempt or nothing, never the one that has taken its place.
    @Test func aNoticeForAnAttemptThatIsOverLeavesTheCurrentOneAlone() async {
        let harness = await harness()
        await harness.dragSelect()
        let finished = await harness.coordinator.lastAttempt?.attempt

        harness.reader.interrupt {
            guard let finished else { return }
            await harness.coordinator.invalidate(.focusChanged, of: finished)
        }
        await harness.dragSelect()

        #expect(harness.presenter.shown.count == 2)
        #expect(await harness.coordinator.lastAttempt?.invalidation == nil)
    }
}
