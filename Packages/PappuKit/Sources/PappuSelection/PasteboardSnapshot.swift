import Foundation

/// Why no snapshot was taken, and so why the clipboard fallback did not run (ACT-10b).
///
/// Each case is a reason the fallback is *skipped*, which leaves the pasteboard untouched. None of them
/// is a failure: a transaction that never opens cannot lose anybody's clipboard.
public enum SnapshotRefusal: String, Sendable, Codable, CaseIterable, Error {
    /// `NSPasteboard.accessBehavior` is `ask` or `alwaysDeny`, so a read would prompt or fail
    /// (architecture §19 item 3). Read before the pasteboard is, so no prompt is raised by finding out.
    case accessNotAllowed
    /// A file promise. Its bytes do not exist yet and cannot be recreated, so it cannot be put back.
    case filePromise
    /// A representation that is listed and hands back no data. M0 spike 6 found this for a promise
    /// whose owner had died, and treats it the same as a promise: unrestorable.
    case unreadableRepresentation
    /// Over the memory ceiling. Not a time limit — 50 MB takes 35 ms — but a limit on how much of
    /// somebody's clipboard we are willing to hold a second copy of.
    case tooLarge
    /// The read did not come back inside its deadline, which means an app is sitting on a lazy
    /// provider. The thread that waits for it is abandoned and may outlive this transaction.
    case deadlineExpired
}

/// Every item and every representation of the pasteboard, as it was before the transaction (ACT-10a).
///
/// A snapshot exists only when it is faithful: `take(from:ceilingBytes:)` refuses rather than build a
/// partial one, so there is no such thing as a snapshot that cannot be put back. The `Skipped` branch of
/// architecture §5 is therefore not a rule the broker has to remember — it is the error case of this
/// initialiser.
///
/// It keeps the order of items and of each item's types, because restoring in a different order would
/// change which representation an app picks up.
public struct PasteboardSnapshot: Sendable, Equatable {
    /// The count the pasteboard stood at when the snapshot was taken. Restoring compares against it.
    public let changeCount: Int
    public let items: [[PasteboardRepresentation]]

    init(changeCount: Int, items: [[PasteboardRepresentation]]) {
        self.changeCount = changeCount
        self.items = items
    }

    public var representationCount: Int { items.reduce(0) { $0 + $1.count } }
    public var bytes: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }
    public var isEmpty: Bool { items.isEmpty }

    /// **Blocks** for as long as the app that owns the pasteboard takes to hand over its lazy data, which
    /// may be forever. Call it through `Abandonable.run(within:)` and never on a thread that matters.
    ///
    /// The count is read first and again at the end: a pasteboard that changed under the snapshot was
    /// never one whole thing, and putting it back would mix two clipboards.
    public static func take(from pasteboard: any PasteboardProviding, ceilingBytes: Int) -> Result<PasteboardSnapshot, SnapshotRefusal> {
        guard pasteboard.accessBehavior.readsWithoutAPrompt else { return .failure(.accessNotAllowed) }
        let before = pasteboard.changeCount
        let types = pasteboard.itemTypes()
        var items: [[PasteboardRepresentation]] = []
        var total = 0
        for (index, itemTypes) in types.enumerated() {
            var representations: [PasteboardRepresentation] = []
            for type in itemTypes {
                // Asked before the bytes are, because reading a promise is what makes it unanswerable.
                guard !PasteboardRepresentation(type: type, data: Data()).isPromise else {
                    return .failure(.filePromise)
                }
                guard let data = pasteboard.data(item: index, type: type) else {
                    return .failure(.unreadableRepresentation)
                }
                total += data.count
                guard total <= ceilingBytes else { return .failure(.tooLarge) }
                representations.append(PasteboardRepresentation(type: type, data: data))
            }
            items.append(representations)
        }
        // A write that landed while we were reading means the items we hold came from two clipboards.
        guard pasteboard.changeCount == before else { return .failure(.unreadableRepresentation) }
        return .success(PasteboardSnapshot(changeCount: before, items: items))
    }

    /// The items to write back, each carrying ACT-10h's markers.
    ///
    /// A marker already on an item is left alone rather than added twice; the rest are added with no
    /// bytes behind them, which is the convention the markers are read by.
    public func markedItems() -> [[PasteboardRepresentation]] {
        items.map { representations in
            let present = Set(representations.map(\.type))
            return representations + PasteboardMarker.all
                .filter { !present.contains($0) }
                .map { PasteboardRepresentation(type: $0, data: Data()) }
        }
    }

    /// Puts the snapshot back, and says what the pasteboard did while it happened.
    ///
    /// **Restoring is two calls and cannot be made one.** Between the count check the caller has already
    /// made and the `clear()` here there is a gap — 0.13–0.15 ms at p95 with nobody else writing, 0.36 ms
    /// with another process writing every millisecond — in which a newer write can be destroyed. That
    /// cannot be prevented. It can be *known*, by comparing what clearing returns with the count we
    /// expected it to leave, and knowing it is what makes ACT-10f reportable instead of merely intended.
    ///
    /// An empty snapshot is put back as an empty pasteboard: clearing is the whole of it, and writing no
    /// items would leave the count moved with somebody else's content still readable.
    public func restore(to pasteboard: any PasteboardProviding, expecting checked: Int) -> RestoreReport {
        let cleared = pasteboard.clear()
        let final = isEmpty ? cleared : pasteboard.write(markedItems())
        return RestoreReport(cleared: cleared, final: final, destroyedANewerWrite: cleared > checked + 1)
    }

    public struct RestoreReport: Sendable, Equatable {
        /// What `clear()` returned.
        public let cleared: Int
        /// Where the count stood once our own write was through. The broker keeps it so that it can
        /// recognise its own write in the drain that follows.
        public let final: Int
        /// Clearing moved the count by more than one, so somebody wrote in the gap and we destroyed it.
        public let destroyedANewerWrite: Bool
    }
}
