import CoreGraphics
import PappuSelection

/// The window levels spike 1 puts on trial. Named rather than numbered so that the configuration below
/// is a value a test can read without AppKit, and so that a change to it is legible in a diff.
public enum BarWindowLevel: String, Sendable, Codable, CaseIterable {
    case floating
    case statusBar
    case popUpMenu
    case screenSaver
}

/// How the bar's panel is built (architecture §7).
///
/// It is data for the same reason `DetectionPolicies` is: the mechanism was buildable before the
/// measurement that settles it. Spike 1 runs sixteen level × collection-behaviour combinations against a
/// fullscreen app, a second Space, Stage Manager and a second display, and its answer is the level below.
/// Until that run happens with somebody watching the screen, `bar` is the design's expectation and says
/// so — **provisional** — and nothing else in the module depends on which value it holds.
///
/// `canBecomeKey` is false and stays false. It is BAR-1's whole substance: a bar that could take key
/// focus would move the focused element out from under `DestinationVerifier`, and RUN-1c rests on its
/// not doing so. The palette, the prompt and the result panel of M3 and M4 are key-capable *and*
/// non-activating, which is a different configuration and will be its own value here.
public struct BarPanelConfiguration: Sendable, Equatable {
    public var level: BarWindowLevel
    /// So the bar is there in whichever Space the user is in (BAR-2).
    public var joinsAllSpaces: Bool
    /// So it is there over a fullscreen app (BAR-2).
    public var isFullScreenAuxiliary: Bool
    public var canBecomeKey: Bool
    /// `.nonactivatingPanel`: a click on the bar does not bring PappuClip forward (BAR-1).
    public var isNonActivating: Bool
    /// PappuClip is never the active application, so a panel that hid on deactivation would never show.
    public var hidesOnDeactivate: Bool
    /// The bar is borderless and draws its own background and arrow.
    public var isBorderless: Bool

    public init(
        level: BarWindowLevel,
        joinsAllSpaces: Bool,
        isFullScreenAuxiliary: Bool,
        canBecomeKey: Bool,
        isNonActivating: Bool,
        hidesOnDeactivate: Bool,
        isBorderless: Bool
    ) {
        self.level = level
        self.joinsAllSpaces = joinsAllSpaces
        self.isFullScreenAuxiliary = isFullScreenAuxiliary
        self.canBecomeKey = canBecomeKey
        self.isNonActivating = isNonActivating
        self.hidesOnDeactivate = hidesOnDeactivate
        self.isBorderless = isBorderless
    }

    /// Provisional until spike 1's matrix run (docs/spikes/RUNBOOK.md).
    public static let bar = BarPanelConfiguration(
        level: .popUpMenu,
        joinsAllSpaces: true,
        isFullScreenAuxiliary: true,
        canBecomeKey: false,
        isNonActivating: true,
        hidesOnDeactivate: false,
        isBorderless: true
    )
}

/// How wide each button is. AppKit measures text in the app; a test says a number.
public protocol BarMeasuring: Sendable {
    func widths(for content: BarContent, metrics: BarMetrics) -> [CGFloat]
}

/// The window the bar lives in. `BarPanel` in the app, a recorder in the tests.
///
/// It is deliberately dumb: it draws what it is told, and every decision — where, what, which button is
/// highlighted, when it goes away — is `BarController`'s and is made in a value type that a test can
/// drive. What is left here is the part that needs a window server, and that is the part no test covers.
@MainActor
public protocol BarWindowing: AnyObject {
    var events: (any BarWindowEvents)? { get set }
    var isVisible: Bool { get }
    /// In top-left screen coordinates, to match everything else in the module. `.null` when hidden.
    var frame: CGRect { get }

    /// Build the panel and its views ahead of any bar, so that showing one is a move and an order-front
    /// rather than a construction (PRD §11.1's 30 ms render stage; spike 1 measured p95 1.9 ms).
    func prepare()
    func show(_ content: BarContent, placement: BarPlacement, appearance: BarAppearance, metrics: BarMetrics)
    func highlight(_ index: Int?)
    func present(_ feedback: BarFeedbackState, motion: BarMotion)
    /// Post an accessibility announcement from the bar (BAR-14).
    func announce(_ message: String)
    func hide()
}

/// What the window tells the controller: the one thing only AppKit sees.
///
/// Hovering is not on the list. The pointer moving over a button changes the highlight and shows a
/// tooltip, and both of those are the window's own business; nothing the controller decides turns on
/// them. In particular the bar does not go away because the pointer left it — BAR-10's reasons are all
/// events the taps see, and there is no global pointer-moved stream to see anything else with.
@MainActor
public protocol BarWindowEvents: AnyObject {
    /// A button was pressed, with the modifiers that were down at the time (BAR-11).
    func barPressed(_ item: BarItemID, modifiers: PointerEvent.Modifiers)
}

/// The key tap, as the bar needs it: held only while a bar is up, and released the moment it goes
/// (ACT-19). Nil means macOS refused the tap, which is what a missing Accessibility grant looks like —
/// the bar still appears, with no keyboard mode and no key dismissal.
public protocol BarKeyLeasing: Sendable {
    func leaseKeys(_ handler: @escaping @Sendable (KeyPress) -> TapDisposition) -> (any InputWatch)?
}

extension EventTapService: BarKeyLeasing {
    public func leaseKeys(_ handler: @escaping @Sendable (KeyPress) -> TapDisposition) -> (any InputWatch)? {
        leaseKeyTap(handler)
    }
}
