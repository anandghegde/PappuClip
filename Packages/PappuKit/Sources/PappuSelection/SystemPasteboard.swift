import AppKit
import Foundation

/// `NSPasteboard.general` behind the broker's seam (architecture §5, §17).
///
/// `@unchecked Sendable` because `NSPasteboard` is a class with no `Sendable` conformance. What makes
/// it safe here is not a lock in this type: the pasteboard is a server the calls go out to, and the
/// ordering the broker depends on comes from its single open-transaction slot. A thread abandoned by
/// `ClipboardScheduling.run(within:)` may still be inside `data(forType:)` while a later transaction
/// runs — that call reads and returns into a box nobody looks at, which is why abandoning is safe and
/// why nothing here writes.
public final class SystemPasteboard: PasteboardProviding, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// `@unknown default` is `.ask`, which refuses: a behaviour this build has never heard of is not
    /// one to read the user's clipboard under (architecture §19 item 3).
    public var accessBehavior: PasteboardAccess {
        guard #available(macOS 15.4, *) else { return .systemDefault }
        switch pasteboard.accessBehavior {
        case .default: return .systemDefault
        case .ask: return .ask
        case .alwaysAllow: return .alwaysAllow
        case .alwaysDeny: return .alwaysDeny
        @unknown default: return .ask
        }
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func itemTypes() -> [[String]] {
        (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    public func data(item index: Int, type: String) -> Data? {
        guard let items = pasteboard.pasteboardItems, items.indices.contains(index) else { return nil }
        return items[index].data(forType: NSPasteboard.PasteboardType(type))
    }

    public func text() -> String? {
        pasteboard.string(forType: .string)
    }

    public func clear() -> Int {
        pasteboard.clearContents()
    }

    public func write(_ items: [[PasteboardRepresentation]]) -> Int {
        let written = items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        pasteboard.writeObjects(written)
        return pasteboard.changeCount
    }
}
