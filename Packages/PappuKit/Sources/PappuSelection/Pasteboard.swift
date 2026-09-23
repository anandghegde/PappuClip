import Foundation

/// One representation of one pasteboard item: a type name and the bytes behind it.
///
/// The type is a `String` and not an `NSPasteboard.PasteboardType` because nothing above
/// `SystemPasteboard` may need AppKit, and because a snapshot has to be able to hold a type name it
/// has never heard of and put it back unchanged (ACT-10a).
public struct PasteboardRepresentation: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// `NSPasteboard.PasteboardType.string`, spelled out because nothing above `SystemPasteboard` may
    /// need AppKit. It is the only type PappuClip ever *writes* text as: an action's result is text and
    /// the app it goes into reads it as text.
    public static let plainText = "public.utf8-plain-text"

    /// One plain-text representation, which is what a paste holds.
    public static func text(_ text: String) -> PasteboardRepresentation {
        PasteboardRepresentation(type: plainText, data: Data(text.utf8))
    }

    /// The five types `NSFilePromiseProvider` writes all carry this word, which is how M0 spike 6
    /// recognised every one of them. Older `NSFilesPromisePboardType` and third-party lazy types were
    /// not tried, so this is a rule about names and not a complete list.
    public var isPromise: Bool {
        type.range(of: "promise", options: .caseInsensitive) != nil
    }
}

/// What macOS will let a programmatic read of the general pasteboard do
/// (`NSPasteboard.AccessBehavior`, macOS 15.4+; architecture §19 item 3).
///
/// It is readable *before* the pasteboard is, which is the property the broker leans on: it can refuse
/// a transaction without ever causing a prompt to appear.
public enum PasteboardAccess: String, Sendable, Codable, CaseIterable {
    /// `.default`: the user has made no choice, and what macOS then does is its own business. Also what
    /// the broker assumes on a macOS with no such property at all.
    ///
    /// M0 spike 6 did not see this value — SpikeLab read `alwaysAllow` on macOS 26.4.1 — so that a read
    /// under it never prompts is an assumption and not a measurement.
    case systemDefault
    case ask
    case alwaysAllow
    case alwaysDeny

    /// Whether a read may go ahead. `ask` is refused rather than tried: a prompt in the middle of a
    /// 270 ms read stage is worse for the user than no bar, and there is nobody to answer it.
    public var readsWithoutAPrompt: Bool {
        switch self {
        case .alwaysAllow, .systemDefault: true
        case .ask, .alwaysDeny: false
        }
    }
}

/// The seam between `ClipboardBroker` and `NSPasteboard.general` (architecture §5, §17).
///
/// Two calls here can block for as long as the app that owns the pasteboard likes, because a lazy
/// provider is served by that app's main thread and a provider that hangs cannot be cancelled (M0
/// spike 6 watched one for twelve seconds). They are marked, and the broker runs each of them where it
/// can walk away from it; nothing in this protocol may be called straight from an actor whose thread
/// matters.
///
/// The cheap calls are cheap by measurement, not by hope: one `changeCount` read is 0.0006 ms at p95
/// and is not a round trip to the pasteboard server.
public protocol PasteboardProviding: Sendable {
    var accessBehavior: PasteboardAccess { get }
    /// Cheap.
    var changeCount: Int { get }
    /// The type names of every item, in order, without reading a byte of any of them.
    func itemTypes() -> [[String]]
    /// **May block.** Nil when the representation is listed and hands nothing back, which M0 spike 6
    /// saw for a promise whose owner had died.
    func data(item: Int, type: String) -> Data?
    /// **May block.** The plain text of the pasteboard, or nil when no item carries any.
    func text() -> String?
    /// - Returns: The change count clearing left behind, which is one more than before when nobody
    ///   else wrote in between. Comparing it with the count we checked is the only way to *know* that a
    ///   newer write was destroyed in the gap (ACT-10f, spike 6).
    func clear() -> Int
    /// Only ever called straight after `clear()`, which is what `NSPasteboard` requires of a writer and
    /// what makes the pair of them one restore.
    /// - Returns: The change count after the write.
    func write(_ items: [[PasteboardRepresentation]]) -> Int
}

/// The two markers of ACT-10h, which ask a clipboard manager not to record a write.
///
/// The broker puts them on its own writes, and it makes two kinds. A restore puts back a snapshot the
/// manager has already seen once, so without the markers every fallback read would leave a duplicate
/// entry in every manager on the Mac. A paste (RUN-4) holds an action's result for a few milliseconds,
/// and that is a value the user never copied at all, so recording it would be worse still. ACT-10i is the other half of this, and it is a promise to measure
/// rather than to claim: nothing here makes a write invisible.
public enum PasteboardMarker {
    public static let transient = "org.nspasteboard.TransientType"
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let all = [transient, concealed]
}
