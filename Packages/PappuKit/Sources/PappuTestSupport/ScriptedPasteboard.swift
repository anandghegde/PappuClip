import Foundation
import PappuSelection
import Synchronization

/// A pasteboard, a clock and a script of what the rest of the Mac does, in one object.
///
/// The three are one type because a clipboard race is one story: "at 5 ms somebody else writes, at 20 ms
/// the app copies, at 21 ms the text appears". Splitting the clock from the pasteboard would let a test
/// say when something happened but not what the broker saw when it looked, which is half a race.
///
/// Nothing here waits. `sleep(for:)` advances a virtual clock and fires whatever the script says is due,
/// so a 400 ms drain costs a test nothing and the same seed gives the same interleaving every time.
///
/// It models the two things M0 spike 6 found that a naive fake would get wrong:
///
/// - **The count moves on the clear, not on the write.** A `copy` bumps the count at its own time and
///   the text appears `textDelay` later, so a broker that reads the moment the count moves finds
///   nothing — which is exactly what happens on a real Mac.
/// - **The restore's gap is real.** `foreignWriteInRestoreGap` lands a write between the broker's last
///   count check and its `clear()`, which is the 0.13–0.36 ms nobody can close (ACT-10f).
public final class ScriptedPasteboard: PasteboardProviding, ClipboardScheduling, SyntheticCopyPosting,
    SyntheticCutPosting, SyntheticPastePosting, InputEpochReading, Sendable
{
    public static let textType = PasteboardRepresentation.plainText

    public enum Action: Sendable, Equatable {
        /// The app under test answers the ⌘C.
        case copy(String)
        /// Anybody else writes: another app, a clipboard manager, the user's own ⌘C.
        case foreignWrite(String)
        /// A clear with no write behind it. What a writer that has started and not finished looks like.
        case clearOnly
        /// The user presses a key or clicks. Moves the input epoch.
        case input
    }

    /// One thing the world does, at a time measured from the synthetic keystroke — the ⌘C of a read,
    /// or the ⌘V of a write. Either one starts the script, because either one is where a transaction's
    /// story starts.
    public struct Event: Sendable, Equatable {
        public let action: Action
        public let at: Duration

        public init(_ action: Action, at: Duration) {
            self.action = action
            self.at = at
        }

        public static func copy(_ text: String, at: Duration) -> Event { Event(.copy(text), at: at) }
        public static func foreignWrite(_ text: String, at: Duration) -> Event { Event(.foreignWrite(text), at: at) }
        public static func clearOnly(at: Duration) -> Event { Event(.clearOnly, at: at) }
        public static func input(at: Duration) -> Event { Event(.input, at: at) }
    }

    private enum Due: Sendable {
        /// A clear, with what will appear afterwards.
        case clearing([[PasteboardRepresentation]])
        /// The write that follows a clear, `textDelay` later.
        case materialise([[PasteboardRepresentation]])
        case input
    }

    private struct State {
        var now: ContinuousClock.Instant
        var script: [Event] = []
        var due: [(at: ContinuousClock.Instant, what: Due)] = []
        var items: [[PasteboardRepresentation]] = []
        var changeCount = 1
        var access: PasteboardAccess = .alwaysAllow
        var epoch: UInt64 = 0

        var textDelay: Duration = .zero
        /// How long every abandonable read takes. Above the broker's limit it is abandoned, which is how
        /// a hung lazy provider is played.
        var readCost: Duration = .zero
        var keyTapIsAvailable = true
        var copyCanBePosted = true
        var cutCanBePosted = true
        var pasteCanBePosted = true
        var unreadableTypes: Set<String> = []
        var gapWrite: [[PasteboardRepresentation]]?

        var clears = 0
        var brokerWrites: [[[PasteboardRepresentation]]] = []
        var copyPosts = 0
        var cutPosts = 0
        var pastePosts = 0
        var watches = 0
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - text: What is on the user's clipboard before anything happens. Nil for an empty pasteboard.
    ///   - script: What the rest of the Mac does, timed from the synthetic ⌘C. Before the ⌘C is posted
    ///     nothing in it fires, which is deliberate: the transaction's story starts there.
    public init(
        text: String? = "the user's own clipboard",
        script: [Event] = [],
        start: ContinuousClock.Instant = .now
    ) {
        var initial = State(now: start)
        initial.script = script.sorted { $0.at < $1.at }
        initial.items = text.map { [Self.representations(for: $0)] } ?? []
        state = Mutex(initial)
    }

    // MARK: Setting the scene

    public func set(access: PasteboardAccess) {
        state.withLock { $0.access = access }
    }

    /// How long after the count moves the text appears. Spike 6 measured 0.14–0.28 ms at p50 and found
    /// no upper bound for a slow writer.
    public func set(textDelay: Duration) {
        state.withLock { $0.textDelay = textDelay }
    }

    /// Makes every abandonable read cost this much. Above `ClipboardTiming.snapshotMs` the snapshot is
    /// abandoned; between `textWaitMs` and `snapshotMs`, only the text read is.
    public func set(readCost: Duration) {
        state.withLock { $0.readCost = readCost }
    }

    public func set(keyTapIsAvailable: Bool) {
        state.withLock { $0.keyTapIsAvailable = keyTapIsAvailable }
    }

    public func set(copyCanBePosted: Bool) {
        state.withLock { $0.copyCanBePosted = copyCanBePosted }
    }

    /// Whether the ⌘V goes out. False is the event-tap refusal the write path has to survive without
    /// leaving the action's text on the user's clipboard.
    public func set(cutCanBePosted: Bool) {
        state.withLock { $0.cutCanBePosted = cutCanBePosted }
    }

    public func set(pasteCanBePosted: Bool) {
        state.withLock { $0.pasteCanBePosted = pasteCanBePosted }
    }

    /// Puts items on the pasteboard directly, for the snapshot's refusals: a promise, or a type that
    /// lists itself and hands back nothing.
    public func put(_ items: [[PasteboardRepresentation]], unreadable: Set<String> = []) {
        state.withLock {
            $0.items = items
            $0.unreadableTypes = unreadable
        }
    }

    /// Lands a write inside the restore's gap — between the broker's last count check and its `clear()`.
    /// The gap is 0.13 ms on an idle Mac and cannot be closed, only noticed (ACT-10f).
    public func writeInRestoreGap(_ text: String) {
        state.withLock { $0.gapWrite = [Self.representations(for: text)] }
    }

    // MARK: Watching

    public var currentText: String? { state.withLock { Self.text(of: $0.items) } }
    public var currentTypes: [[String]] { state.withLock { $0.items.map { $0.map(\.type) } } }
    public var clears: Int { state.withLock { $0.clears } }
    public var copyPosts: Int { state.withLock { $0.copyPosts } }
    public var cutPosts: Int { state.withLock { $0.cutPosts } }
    public var pastePosts: Int { state.withLock { $0.pastePosts } }
    public var watches: Int { state.withLock { $0.watches } }
    /// Every set of items the broker wrote, in order. A restore is one of these.
    public var brokerWrites: [[[PasteboardRepresentation]]] { state.withLock { $0.brokerWrites } }
    /// Whether the last thing the broker wrote asked clipboard managers to ignore it (ACT-10h).
    public var lastWriteWasMarked: Bool {
        state.withLock { state in
            guard let last = state.brokerWrites.last, !last.isEmpty else { return false }
            return last.allSatisfy { item in
                PasteboardMarker.all.allSatisfy { marker in item.contains { $0.type == marker } }
            }
        }
    }

    /// Pass as the `now` of an `AttemptClock`, so the attempt's budget and the script share one clock.
    public var reader: @Sendable () -> ContinuousClock.Instant {
        { self.now }
    }

    // MARK: ClipboardScheduling

    public var now: ContinuousClock.Instant { state.withLock { $0.now } }

    public func sleep(for duration: Duration) async {
        guard duration > .zero else { return }
        advance(by: duration)
        // Every wait is a real suspension point even though no time passes, so that two transactions
        // racing for the broker's slot interleave here the way they would on a real clock.
        await Task.yield()
    }

    public func run(within limit: Duration, _ work: @escaping @Sendable () -> Void) async -> Bool {
        guard limit > .zero else { return false }
        let cost = state.withLock { $0.readCost }
        guard cost <= limit else {
            // The read is still going. The broker walks away; time passed all the same.
            advance(by: limit)
            await Task.yield()
            return false
        }
        advance(by: cost)
        work()
        await Task.yield()
        return true
    }

    // MARK: PasteboardProviding

    public var accessBehavior: PasteboardAccess { state.withLock { $0.access } }

    public var changeCount: Int { state.withLock { $0.changeCount } }

    public func itemTypes() -> [[String]] {
        state.withLock { $0.items.map { $0.map(\.type) } }
    }

    public func data(item index: Int, type: String) -> Data? {
        state.withLock { state in
            guard !state.unreadableTypes.contains(type), state.items.indices.contains(index) else { return nil }
            return state.items[index].first { $0.type == type }?.data
        }
    }

    public func text() -> String? {
        state.withLock { Self.text(of: $0.items) }
    }

    public func clear() -> Int {
        state.withLock { state in
            if let gap = state.gapWrite {
                state.gapWrite = nil
                state.changeCount += 1
                state.items = gap
            }
            state.clears += 1
            state.changeCount += 1
            state.items = []
            return state.changeCount
        }
    }

    public func write(_ items: [[PasteboardRepresentation]]) -> Int {
        state.withLock { state in
            state.brokerWrites.append(items)
            state.items = items
            // Writing does not move the count. Only clearing does, which is the whole of spike 6's
            // first surprise.
            return state.changeCount
        }
    }

    // MARK: SyntheticCopyPosting

    /// Starts the script's clock: every `Event.at` is measured from here.
    public func postCopy() -> Bool {
        post { $0.copyCanBePosted } counting: { $0.copyPosts += 1 }
    }

    // MARK: SyntheticCutPosting

    /// Cut's ⌘X. It starts the script's clock like the other two, and it writes nothing here: on a real
    /// Mac the *app* puts the selection on the clipboard in response, which a test that cares about
    /// says with an `Event.copy` at the delay it wants.
    public func postCut() -> Bool {
        post { $0.cutCanBePosted } counting: { $0.cutPosts += 1 }
    }

    // MARK: SyntheticPastePosting

    /// The other synthetic keystroke, and the other place a script can start. A write transaction never
    /// posts a ⌘C, so the events of a paste test are timed from here: a foreign write "at 10 ms" is one
    /// that lands 10 ms into the hold.
    public func postPaste() -> Bool {
        post { $0.pasteCanBePosted } counting: { $0.pastePosts += 1 }
    }

    private func post(
        _ allowed: (State) -> Bool,
        counting count: (inout State) -> Void
    ) -> Bool {
        let posted: Bool = state.withLock { state in
            guard allowed(state) else { return false }
            count(&state)
            for event in state.script {
                state.due.append((at: state.now.advanced(by: event.at), what: Self.due(for: event.action)))
            }
            state.script = []
            state.due.sort { $0.at < $1.at }
            return true
        }
        // A script event at zero is due the moment the key goes down.
        if posted { advance(by: .zero) }
        return posted
    }

    // MARK: InputEpochReading

    public var inputEpoch: InputEpoch { InputEpoch(rawValue: state.withLock { $0.epoch }) }

    public func watchInput() -> (any InputWatch)? {
        state.withLock { state in
            guard state.keyTapIsAvailable else { return nil }
            state.watches += 1
            return Watch()
        }
    }

    private final class Watch: InputWatch {
        func stop() {}
    }

    // MARK: The clock

    private func advance(by duration: Duration) {
        state.withLock { state in
            let target = state.now.advanced(by: duration)
            while let next = state.due.first, next.at <= target {
                state.due.removeFirst()
                if next.at > state.now { state.now = next.at }
                Self.apply(next.what, to: &state)
            }
            if target > state.now { state.now = target }
        }
    }

    private static func apply(_ what: Due, to state: inout State) {
        switch what {
        case .clearing(let items):
            state.changeCount += 1
            state.items = []
            if state.textDelay > .zero {
                state.due.append((at: state.now.advanced(by: state.textDelay), what: .materialise(items)))
                state.due.sort { $0.at < $1.at }
            } else {
                state.items = items
            }
        case .materialise(let items):
            state.items = items
        case .input:
            state.epoch += 1
        }
    }

    private static func due(for action: Action) -> Due {
        switch action {
        case .copy(let text), .foreignWrite(let text): .clearing([representations(for: text)])
        case .clearOnly: .clearing([])
        case .input: .input
        }
    }

    private static func representations(for text: String) -> [PasteboardRepresentation] {
        [PasteboardRepresentation(type: textType, data: Data(text.utf8))]
    }

    private static func text(of items: [[PasteboardRepresentation]]) -> String? {
        for item in items {
            if let representation = item.first(where: { $0.type == textType }) {
                return String(decoding: representation.data, as: UTF8.self)
            }
        }
        return nil
    }
}
