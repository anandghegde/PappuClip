import CoreGraphics

/// One display, as the bar's placement sees it.
///
/// **Coordinates.** Everything in `PappuSurfaces` that describes a position on screen uses the space
/// the bar's inputs already arrive in: the origin is the top-left of the main display and y grows
/// downwards. That is what a `CGEvent` reports for the pointer and what the Accessibility tree
/// reports for `AXBoundsForRange`, so the placement can be computed without converting anything and
/// without a window server. AppKit's own space, which is flipped, is reached exactly once, in
/// `BarPanel`, and `flipped(_:inMainDisplayHeight:)` is the only conversion in the module.
public struct BarScreen: Sendable, Equatable, Identifiable {
    /// `CGDirectDisplayID` in the app; any stable number in a test.
    public var id: Int
    /// The whole display.
    public var frame: CGRect
    /// The display minus the menu bar and the Dock. The bar is clamped to this (BAR-2).
    public var visibleFrame: CGRect

    public init(id: Int, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// The one conversion between AppKit's bottom-left space and ours.
    ///
    /// AppKit measures from the bottom of the *main* display, so a rectangle on a display above or
    /// below it has a negative or large y. Flipping is an involution: applying it twice gives the
    /// rectangle back, which is what its test asserts rather than a table of numbers.
    public static func flipped(_ rect: CGRect, inMainDisplayHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension Array where Element == BarScreen {
    /// The display the bar belongs on (BAR-2): the one holding the selection, and the one holding the
    /// pointer when the app would not say where the selection is.
    ///
    /// A selection can straddle two displays — a window dragged across the join — so "holding" is the
    /// largest overlap rather than a containment test, and the point falls back to the pointer and
    /// then to the first display, which is the main one as `NSScreen.screens` orders them.
    public func screen(holding bounds: CGRect?, or pointer: CGPoint?) -> BarScreen? {
        if let bounds, !bounds.isNull, !bounds.isEmpty {
            let overlapping = self
                .map { ($0, $0.frame.intersection(bounds)) }
                .filter { !$0.1.isNull && !$0.1.isEmpty }
                .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            if let overlapping { return overlapping.0 }
            if let containing = first(where: { $0.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }) {
                return containing
            }
        }
        if let pointer, let containing = first(where: { $0.frame.contains(pointer) }) {
            return containing
        }
        return first
    }
}

/// Where the displays come from. AppKit in the app, a list in a test — which is the only way the
/// placement rules can be tested across display arrangements that no one machine has.
public protocol BarScreenSource: Sendable {
    func screens() -> [BarScreen]
}
