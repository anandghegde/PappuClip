import PappuAX
import PappuCore

/// ACT-9's chain: the strategies a policy named, in order, until one of them answers
/// (architecture §4.5).
///
/// It owns no reading of its own. Strategies 1 and 3 are `AXSelectionReader`'s, on the AX actor;
/// strategy 5 is `ClipboardBroker`'s, on its own; what is here is the order, the budget between them,
/// and the single decision each answer forces: stop, or go on.
///
/// **What "go on" means is the whole of this type.** `StrategyRead.Finding` draws a line the
/// coordinator never sees: a strategy that could not run (`unavailable`) leaves the question open and a
/// strategy that ran and found nothing (`nothing`) closes it. Only when every strategy has said the
/// first does the attempt come back `refused` — which is what stops an app with no Accessibility tree
/// from being reported as an app with no selection, and is why `SelectionRead` and `StrategyRead` are
/// two types.
public struct SelectionStrategyChain: SelectionReading, Sendable {
    /// Strategies a policy may name that this build cannot run (ACT-9).
    ///
    /// Strategy 2 wants `AXTextMarkerRange`, an opaque Core Foundation type the `AXWorld` seam does not
    /// carry; strategy 4 wants Automation consent and the per-browser scripts that are M0 spike 3's to
    /// write. Both are skipped rather than answered, so a Safari selection still reaches strategy 5
    /// instead of being reported as an empty one.
    public static let unimplemented: Set<SelectionStrategyKind> = [.webkitMarkers, .appleScript]

    private let reader: AXSelectionReader
    private let policies: DetectionPolicyStore
    private let broker: ClipboardBroker
    private let coexistence: @Sendable () -> Coexistence

    /// - Parameter coexistence: Read once per synthetic copy, not held. The coordinator asks the same
    ///   question when it builds the chain — PopClip running takes strategy 5 out of it — and the two
    ///   readings can disagree only if PopClip launched between them, in which case the permit is the
    ///   later and therefore the right one (ONB-6, ACT-10j).
    public init(
        reader: AXSelectionReader,
        policies: DetectionPolicyStore,
        broker: ClipboardBroker,
        coexistence: @escaping @Sendable () -> Coexistence = { .none }
    ) {
        self.reader = reader
        self.policies = policies
        self.broker = broker
        self.coexistence = coexistence
    }

    public func read(
        _ permit: consuming ReadPermit,
        attempt: AttemptID,
        chain: [SelectionStrategyKind],
        clock: AttemptClock
    ) async -> SelectionRead {
        let (route, target, scope) = (permit.route, permit.target, permit.scope)

        // ACT-17b: a metadata permit opens the page's address and not a word of what is on it. Every
        // strategy below reads the selection itself, so there is nothing one of them could do with a
        // permit this small — and a read that quietly did less than it was asked would be worse than
        // none, because the caller would not know which it got.
        //
        // `PrivacyGate` mints only `.fullText` today; website hard blocks are 1.0, and this is the line
        // that will already be right when they arrive. It is therefore untested from outside PappuCore,
        // where `ReadPermit.init` lives.
        guard scope == .fullText else { return SelectionRead(outcome: .refused) }

        /// Whether any strategy got as far as a real element. The difference between `nothing` and
        /// `refused` at the end.
        var ran = false
        /// ACT-10e: the length of a selection an Accessibility strategy could see but not read, which is
        /// the only thing that can catch a foreign write arriving one change count ahead of our ⌘C.
        var expectedCharacters: Int?

        for kind in chain {
            // ACT-16a: checked between strategies and not only at the end, so a chain does not spend the
            // clipboard fallback's 350 ms on an attempt the user walked away from during the first 150.
            guard !clock.isPastHardCutoff else { return SelectionRead(outcome: .outOfBudget) }

            // Each strategy is bounded by what is left of the read stage on its own path, which is what
            // makes a slow first strategy cost the second one time rather than the attempt its life.
            let budget = clock.remaining(in: .stage(.read), on: kind.path)

            let read: StrategyRead
            switch kind {
            case .ax:
                read = await reader.read(in: target, timeout: budget)

            case .axEnable:
                // `DetectionPolicy.chain(for:)` already drops strategy 3 from an app with nothing to
                // enable. This is the same question asked where the answer is used, so a chain built by
                // hand — a test, the harness, a future palette — cannot ask for a switch that has no
                // spelling.
                guard let enabling = policies.policy(for: target).axEnable else { continue }
                read = await reader.read(enabling: enabling, in: target, timeout: budget)

            case .webkitMarkers, .appleScript:
                continue // `unimplemented`.

            case .syntheticCopy:
                // Nil is the policy saying no, and it says so for the same reasons that kept strategy 5
                // out of the declared chain. There is nothing to record: the two are one decision read
                // twice (ACT-10j).
                guard let copy = policies.syntheticCopyPermit(
                    attempt: attempt,
                    route: route,
                    target: target,
                    coexistence: coexistence()
                ) else { continue }
                read = Self.read(from: await broker.read(copy, clock: clock, expectedCharacters: expectedCharacters))
            }

            switch read.finding {
            case .text:
                return SelectionRead(
                    outcome: .text,
                    text: read.text,
                    range: read.range,
                    bounds: read.bounds,
                    strategy: kind
                )

            case .caret:
                // ACT-3, and the chain stops here. Going on would reach strategy 5, and a ⌘C at a caret
                // copies whatever the app thinks ⌘C means with nothing selected — in a good many of them
                // the whole line (ACT-10j). A caret is an answer, not a failure to find one.
                return SelectionRead(outcome: .caretOnly, range: read.range, strategy: kind)

            case .nothing:
                ran = true
                // The freshest reading wins: the strategy nearest the ⌘C is the one whose count the
                // pasteboard should match.
                if let range = read.range, !range.isEmpty { expectedCharacters = range.length }

            case .unavailable:
                break
            }
        }

        // Every strategy declined to run: an app with no Accessibility tree, no grant, or a chain whose
        // every member this build cannot run. Not "nothing is selected" — nobody looked.
        return SelectionRead(outcome: ran ? .nothing : .refused)
    }

    /// Strategy 5's answer in the chain's own terms.
    ///
    /// The two halves of `unavailable` are worth naming: a transaction that never opened learned
    /// nothing, and one that opened and could not be trusted learned nothing it is allowed to act on.
    /// Calling either of them `nothing` would turn "we cannot tell" into "there is no selection", which
    /// is the assertion `ClipboardAmbiguity` exists to refuse to make.
    private static func read(from result: ClipboardResult) -> StrategyRead {
        switch result.outcome {
        case .copied:
            guard let text = result.text, !text.isEmpty else { return .nothing }
            // No range and no rectangle: the pasteboard says what was selected and never where, so the
            // bar goes to the pointer (BAR-3).
            return StrategyRead(finding: .text, text: text)
        case .nothingCopied, .noText:
            return .nothing
        case .skipped, .ambiguous:
            return StrategyRead(finding: .unavailable)
        }
    }
}
