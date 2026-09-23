import PappuAX
import PappuCore

/// What a fresh look at the destination found, at the moment the verifier looked (RUN-2).
///
/// Three-valued on purpose. `true` and `false` are answers; `nil` is "could not tell", which is a
/// third thing and is never quietly read as either. Most of the Mac's apps answer some of these and
/// not others — a Chromium window with its tree switched off answers none — and a tier that treated
/// silence as agreement would be no check at all.
public struct DestinationEvidence: Sendable, Equatable {
    /// Whether the app the snapshot names is the frontmost one now.
    public var isFrontmost: Bool?
    /// Whether the frontmost window is the one the snapshot was taken in.
    public var sameWindow: Bool?
    /// Whether the focused element is the one the text was read from (`CFEqual`, via `AXWorld.isSame`).
    public var sameElement: Bool?
    /// Whether that element is still one the user can type into. A read-only destination is not a
    /// destination (FLT-6).
    public var isEditable: Bool?
    /// Where the selection is now, for comparison against the snapshot's range.
    public var range: AXTextRange?
    /// What the selection is now, as a hash. Reading it spends the execution permit.
    public var text: TextDigest?
    /// The first thing Accessibility would not do. Not a refusal on its own — the fields above say
    /// what is missing — but it is what the inspector shows when a tier is out of reach (DIA-2).
    public var fault: AXFault?

    public init(
        isFrontmost: Bool? = nil,
        sameWindow: Bool? = nil,
        sameElement: Bool? = nil,
        isEditable: Bool? = nil,
        range: AXTextRange? = nil,
        text: TextDigest? = nil,
        fault: AXFault? = nil
    ) {
        self.isFrontmost = isFrontmost
        self.sameWindow = sameWindow
        self.sameElement = sameElement
        self.isEditable = isEditable
        self.range = range
        self.text = text
        self.fault = fault
    }

    /// What the probe reports when it could not look at all: no grant, no handle, nothing captured.
    public static func unanswered(_ fault: AXFault? = nil) -> DestinationEvidence {
        DestinationEvidence(fault: fault)
    }
}

/// The Accessibility side of destination verification (architecture §8.2).
///
/// It is a seam for the same reason every AX-facing thing here is one: the real implementation needs
/// the grant, a window server and another app to talk to, and the rules that consume it need none of
/// those. `AXDestinationProbe` is the real one; a scripted fake stands in for it in the tests.
///
/// Three calls, in the order an invocation makes them:
///
/// 1. `capture(_:)` at `InvocationManager.begin`, which takes hold of the focused window and element
///    and hands back a `DestinationHandle` for them.
/// 2. `look(for:in:permit:)` at every verification, which compares the world against what it holds
///    and reads the selection. Reading the selection is a read, so it spends a `ReadPermit` minted by
///    the execution-time recheck (RUN-2f).
/// 3. `release(_:)` when the invocation ends, so nothing holds an element of a window that has closed.
public protocol DestinationProbing: Sendable {
    /// - Returns: Nil when there was nothing to take hold of, which is ordinary: an app with no
    ///   Accessibility tree has no focused element to capture, and such an invocation can only ever
    ///   reach the quiescence tier.
    func capture(_ target: TargetApp) async -> DestinationHandle?

    /// - Parameter frontmost: The app in front right now, read by the caller from `NSWorkspace` — the
    ///   probe does not depend on AppKit. Nil when nothing is frontmost.
    func look(
        for handle: DestinationHandle?,
        in target: TargetApp,
        frontmost: TargetApp?,
        permit: consuming ReadPermit
    ) async -> DestinationEvidence

    func release(_ handle: DestinationHandle) async
}
