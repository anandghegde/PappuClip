import CoreGraphics
import PappuAX
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

// MARK: The scene

private let target = TargetApp(pid: 501, bundleID: "com.example.editor")
private let selection = AXTextRange(location: 4, length: 5)
private let caret = AXTextRange(location: 4, length: 0)
private let rect = CGRect(x: 10, y: 20, width: 60, height: 16)

/// `#require` cannot hold a `~Copyable` value, so a refused gate throws instead.
private struct TheGateRefused: Error {}

private func permit(route: ActivationRoute = .hotkey) throws -> ReadPermit {
    let decision = PrivacyGate(PrivacyRules()).evaluate(route: route, target: target, secureInput: .clear)
    guard let permit = decision.permit() else { throw TheGateRefused() }
    return permit
}

private func policies(
    strategies: [SelectionStrategyKind] = [.ax],
    axEnable: AXTreeEnabling? = nil,
    syntheticCopy: Bool = false
) -> DetectionPolicyStore {
    DetectionPolicyStore(DetectionPolicies(default: DetectionPolicy(
        strategies: strategies,
        autoAppear: true,
        autoSyntheticCopy: syntheticCopy,
        hotkeySyntheticCopy: syntheticCopy,
        quiescence: true,
        axEnable: axEnable
    )))
}

/// A focused element with whatever the test wants in it.
private func world(text: String? = "hello", range: AXTextRange? = selection, bounds: CGRect? = rect) -> FakeAXWorld {
    let world = FakeAXWorld()
    let node = FakeAXWorld.Node(role: "AXTextArea", selectedRange: range, selectedText: text)
    if let bounds, let range { node.setBounds(bounds, for: range) }
    world.setFocused(node, in: target.pid)
    return world
}

private func chain(
    _ world: FakeAXWorld,
    pasteboard: ScriptedPasteboard = ScriptedPasteboard(text: "the user's own clipboard"),
    policies store: DetectionPolicyStore = policies(),
    coexistence: Coexistence = .none
) async -> SelectionStrategyChain {
    await SelectionStrategyChain(
        reader: AXSelectionReader(world: world),
        policies: store,
        broker: ClipboardBroker(
            pasteboard: pasteboard,
            input: pasteboard,
            copy: pasteboard,
            pasting: pasteboard,
            scheduling: pasteboard,
            timing: .initial
        ),
        coexistence: { coexistence }
    )
}

private func clock(_ pasteboard: ScriptedPasteboard, spentMs: Int = 0) -> AttemptClock {
    AttemptClock(start: pasteboard.now.advanced(by: .milliseconds(-spentMs)), now: pasteboard.reader)
}

/// ACT-9's order, and what each answer does to the strategies behind it (architecture §4.5).
@Suite struct SelectionStrategyChainTests {

    // MARK: First success wins

    @Test func strategyOneAnswersAndNothingBehindItRuns() async throws {
        let pasteboard = ScriptedPasteboard(text: "the user's own clipboard")
        let chain = await chain(world(), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax, .syntheticCopy], clock: clock(pasteboard))

        #expect(read.outcome == .text)
        #expect(read.text == "hello")
        #expect(read.range == selection)
        #expect(read.bounds == rect)
        #expect(read.strategy == .ax)
        // The user's clipboard was never touched, which is the whole point of an order.
        #expect(pasteboard.copyPosts == 0)
        #expect(pasteboard.currentText == "the user's own clipboard")
    }

    /// ACT-3, and the reason a caret ends the chain: ⌘C at a caret copies whatever that app thinks ⌘C
    /// means with nothing selected, which in a good many of them is the whole line (ACT-10j).
    @Test func aCaretStopsTheChainBeforeTheClipboard() async throws {
        let pasteboard = ScriptedPasteboard(text: "the user's own clipboard")
        let chain = await chain(world(range: caret), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax, .syntheticCopy], clock: clock(pasteboard))

        #expect(read.outcome == .caretOnly)
        #expect(read.range == caret)
        #expect(read.strategy == .ax)
        #expect(pasteboard.copyPosts == 0)
    }

    // MARK: Falling through (strategy 5)

    @Test func anAppWithNoTreeReachesTheClipboardFallback() async throws {
        let pasteboard = ScriptedPasteboard(
            text: "the user's own clipboard",
            script: [.copy("selected words", at: .milliseconds(20))]
        )
        let chain = await chain(FakeAXWorld(), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax, .syntheticCopy], clock: clock(pasteboard))

        #expect(read.outcome == .text)
        #expect(read.text == "selected words")
        #expect(read.strategy == .syntheticCopy)
        // BAR-3: the pasteboard says what was selected and never where, so the bar goes to the pointer.
        #expect(read.bounds == nil)
        #expect(pasteboard.currentText == "the user's own clipboard")
    }

    /// ACT-10e: a selection an Accessibility strategy could see but not read tells strategy 5 how long
    /// the answer should be, which is the only check that catches a foreign write one count ahead.
    @Test func theLengthAnEarlierStrategySawIsCheckedAgainstThePasteboard() async throws {
        for (copied, outcome) in [("world", SelectionRead.Outcome.text), ("something else entirely", .nothing)] {
            let pasteboard = ScriptedPasteboard(
                text: "the user's own clipboard",
                script: [.copy(copied, at: .milliseconds(20))]
            )
            // Five characters selected, and the app will not say which.
            let chain = await chain(world(text: nil), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
            let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax, .syntheticCopy], clock: clock(pasteboard))

            #expect(read.outcome == outcome)
        }
    }

    /// ONB-6: two apps racing to simulate ⌘C is the one coexistence failure that loses the user's
    /// clipboard, so the permit is refused and nothing is posted.
    @Test func popClipTakesTheFallbackAwayOnTheAutomaticPath() async throws {
        let pasteboard = ScriptedPasteboard(
            text: "the user's own clipboard",
            script: [.copy("selected words", at: .milliseconds(20))]
        )
        let chain = await chain(
            FakeAXWorld(),
            pasteboard: pasteboard,
            policies: policies(syntheticCopy: true),
            coexistence: Coexistence(popClipIsRunning: true)
        )
        let read = await chain.read(
            try permit(route: .automatic),
            attempt: AttemptID(rawValue: 1),
            chain: [.ax, .syntheticCopy],
            clock: clock(pasteboard)
        )

        #expect(read.outcome == .refused)
        #expect(pasteboard.copyPosts == 0)
    }

    /// A transaction that opened and could not be trusted has learned nothing it may act on, so it is
    /// `refused` and not "there is no selection" — the assertion `ClipboardAmbiguity` exists to refuse.
    @Test func anAmbiguousTransactionIsNotAnEmptySelection() async throws {
        let pasteboard = ScriptedPasteboard(
            text: "the user's own clipboard",
            script: [.foreignWrite("somebody else's", at: .milliseconds(10)), .copy("selected words", at: .milliseconds(20))]
        )
        let chain = await chain(FakeAXWorld(), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax, .syntheticCopy], clock: clock(pasteboard))

        #expect(read.outcome == .refused)
    }

    // MARK: Strategy 3

    @Test func strategyThreeThrowsTheSwitchTheAppsPolicyNames() async throws {
        let app = world()
        let chain = await chain(app, policies: policies(strategies: [.axEnable], axEnable: .manualAccessibility))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.axEnable], clock: clock(ScriptedPasteboard()))

        #expect(read.outcome == .text)
        #expect(read.strategy == .axEnable)
        #expect(app.treeSwitches.map(\.which) == [.manualAccessibility])
    }

    /// Without a spelling to set, strategy 3 is strategy 1 run twice. `DetectionPolicy.chain(for:)`
    /// drops it; this is the same question asked where the answer is used, for a chain built by hand.
    @Test func strategyThreeIsSkippedForAnAppWithNothingToEnable() async throws {
        let app = world()
        let chain = await chain(app, policies: policies(strategies: [.axEnable]))
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.axEnable], clock: clock(ScriptedPasteboard()))

        #expect(read.outcome == .refused)
        #expect(app.treeSwitches.isEmpty)
        #expect(app.asked.isEmpty)
    }

    // MARK: What this build cannot run (ACT-9)

    /// Strategies 2 and 4 are skipped, not answered: reporting them as "nothing here" would stop a
    /// Safari selection ever reaching strategy 5.
    @Test func anUnimplementedStrategyIsSkippedAndNotAnswered() async throws {
        #expect(SelectionStrategyChain.unimplemented == [.webkitMarkers, .appleScript])

        let pasteboard = ScriptedPasteboard(
            text: "the user's own clipboard",
            script: [.copy("selected words", at: .milliseconds(20))]
        )
        let chain = await chain(FakeAXWorld(), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(
            try permit(),
            attempt: AttemptID(rawValue: 1),
            chain: [.webkitMarkers, .appleScript, .syntheticCopy],
            clock: clock(pasteboard)
        )

        #expect(read.outcome == .text)
        #expect(read.strategy == .syntheticCopy)
    }

    @Test func aStrategyBehindAnUnimplementedOneStillRuns() async throws {
        let chain = await chain(world())
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.webkitMarkers, .ax], clock: clock(ScriptedPasteboard()))

        #expect(read.outcome == .text)
        #expect(read.strategy == .ax)
    }

    // MARK: Nothing, refused, and the difference

    /// The distinction `StrategyRead` exists for: nobody looked, so nothing may be concluded.
    @Test func anEmptyChainIsRefusedAndNotEmptyHanded() async throws {
        let chain = await chain(world())
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [], clock: clock(ScriptedPasteboard()))

        #expect(read.outcome == .refused)
        #expect(read.strategy == nil)
    }

    @Test func aStrategyThatRanAndFoundNothingIsNothing() async throws {
        // A real element, a range of zero length nowhere — no, an element that answers neither.
        let empty = FakeAXWorld()
        empty.setFocused(FakeAXWorld.Node(role: "AXTextArea", selectedText: ""), in: target.pid)
        let chain = await chain(empty)
        let read = await chain.read(try permit(), attempt: AttemptID(rawValue: 1), chain: [.ax], clock: clock(ScriptedPasteboard()))

        #expect(read.outcome == .nothing)
        #expect(read.strategy == nil)
    }

    // MARK: The budget (ACT-16a, PRD §11.1)

    @Test func theCutoffIsCheckedBetweenStrategiesAndNotOnlyAtTheEnd() async throws {
        let pasteboard = ScriptedPasteboard(
            text: "the user's own clipboard",
            script: [.copy("selected words", at: .milliseconds(20))]
        )
        let chain = await chain(FakeAXWorld(), pasteboard: pasteboard, policies: policies(syntheticCopy: true))
        let read = await chain.read(
            try permit(),
            attempt: AttemptID(rawValue: 1),
            chain: [.ax, .syntheticCopy],
            clock: clock(pasteboard, spentMs: 800)
        )

        #expect(read.outcome == .outOfBudget)
        #expect(pasteboard.copyPosts == 0)
    }
}
