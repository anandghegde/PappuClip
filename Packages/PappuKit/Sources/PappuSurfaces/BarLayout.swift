import CoreGraphics
import PappuSelection

/// The "Position" setting of BAR-3, which decides single-line selections.
public enum BarPosition: String, Sendable, Codable, CaseIterable {
    case aboveText
    case belowText
}

/// Which side of the anchor the bar ended up on.
public enum BarSide: String, Sendable, Codable, CaseIterable {
    case above
    case below

    var flipped: BarSide { self == .above ? .below : .above }

    init(_ position: BarPosition) {
        self = position == .aboveText ? .above : .below
    }
}

/// What the bar is placed against: where the selection is, where the pointer was let go, and which way
/// the drag went. All three are on `AttemptPresentation` already; this is the subset the geometry uses.
public struct BarAnchor: Sendable, Equatable {
    /// The selection's bounds, when the app gave them. Nil sends the placement to the pointer (BAR-3).
    public var bounds: CGRect?
    /// Where the gesture finished. Nil for the routes with no pointer — the shortcut and scripting.
    public var pointer: CGPoint?
    public var dragDirection: DragDirection?

    public init(bounds: CGRect? = nil, pointer: CGPoint? = nil, dragDirection: DragDirection? = nil) {
        self.bounds = bounds?.isEmptyOrNull == true ? nil : bounds
        self.pointer = pointer
        self.dragDirection = dragDirection
    }

    public init(_ presentation: AttemptPresentation) {
        self.init(
            bounds: presentation.bounds,
            pointer: presentation.pointer,
            dragDirection: presentation.dragDirection
        )
    }
}

/// Where the bar goes, and where its arrow points.
public struct BarPlacement: Sendable, Equatable {
    public struct Arrow: Sendable, Equatable {
        /// The edge of the bar the arrow grows out of. It points at the anchor, so a bar sitting above
        /// the selection carries its arrow on the bottom.
        public var edge: BarSide
        /// The arrow's centre, in the bar's own coordinates.
        public var x: CGFloat
    }

    /// The `BarScreen.id` the bar was placed on (BAR-2).
    public var screen: Int
    /// The bar itself, in top-left screen coordinates. The arrow is drawn outside it.
    public var frame: CGRect
    /// Which side of the anchor it ended up on, after any flip for room.
    public var side: BarSide
    /// Nil when there is nothing honest to point at: the bar had to be clamped away from its anchor.
    public var arrow: Arrow?
    /// How many of the buttons fit. Anything past this belongs to a further page, which is BAR-5a in M4;
    /// until then it is the number a caller should show and the signal that something was left out.
    public var itemsThatFit: Int

    public init(screen: Int, frame: CGRect, side: BarSide, arrow: Arrow?, itemsThatFit: Int) {
        self.screen = screen
        self.frame = frame
        self.side = side
        self.arrow = arrow
        self.itemsThatFit = itemsThatFit
    }

    /// The rectangle the panel occupies: the bar plus its arrow, in top-left screen coordinates.
    ///
    /// This, and not `frame`, is what a click has to miss to count as a click outside the bar — the
    /// arrow is part of the bar to look at and to press. It is a plain function of the placement so
    /// that the window and the dismissal test agree without either asking AppKit.
    public func windowFrame(metrics: BarMetrics) -> CGRect {
        guard let arrow else { return frame }
        return CGRect(
            x: frame.minX,
            y: arrow.edge == .above ? frame.minY - metrics.arrowHeight : frame.minY,
            width: frame.width,
            height: frame.height + metrics.arrowHeight
        )
    }
}

/// BAR-2 and BAR-3 as one pure function over measured widths and a description of the displays.
///
/// Nothing here touches AppKit, so every arrangement a placement rule cares about — a selection on a
/// second display, a selection at the top of the screen with no room above it, a bar wider than the
/// display it is on — is a test rather than a thing to try by hand on hardware nobody has.
public enum BarLayout {
    public static func place(
        anchor: BarAnchor,
        itemWidths: [CGFloat],
        preference: BarPosition = .aboveText,
        metrics: BarMetrics = .standard,
        screens: [BarScreen]
    ) -> BarPlacement? {
        guard let screen = screens.screen(holding: anchor.bounds, or: anchor.pointer) else { return nil }
        let visible = screen.visibleFrame

        let available = visible.width - metrics.screenMargin * 2
        let width = min(metrics.width(forItemWidths: itemWidths), metrics.maximumWidth, max(available, metrics.minimumWidth))
        let itemsThatFit = count(of: itemWidths, fittingIn: width, metrics: metrics)

        let target = self.target(for: anchor, preference: preference, metrics: metrics)

        // The side the rules ask for, and the other one, in the order they are tried.
        var side = target.side
        var y = origin(onSide: side, of: target.rect, height: metrics.height, metrics: metrics)
        var pointsAtAnchor = true
        if !fits(y: y, height: metrics.height, in: visible, metrics: metrics) {
            let flippedY = origin(onSide: side.flipped, of: target.rect, height: metrics.height, metrics: metrics)
            if fits(y: flippedY, height: metrics.height, in: visible, metrics: metrics) {
                side = side.flipped
                y = flippedY
            } else {
                // A selection taller than the display, or a display with no room either side. The bar
                // still appears — that is the requirement — but it no longer points anywhere true.
                y = clamp(y, lower: visible.minY + metrics.screenMargin, upper: visible.maxY - metrics.screenMargin - metrics.height)
                pointsAtAnchor = false
            }
        }

        let unclampedX = target.anchorX - width / 2
        let x = clamp(
            unclampedX,
            lower: visible.minX + metrics.screenMargin,
            upper: max(visible.minX + metrics.screenMargin, visible.maxX - metrics.screenMargin - width)
        )
        let frame = CGRect(x: x, y: y, width: width, height: metrics.height)

        var arrow: BarPlacement.Arrow?
        if pointsAtAnchor, target.anchorX >= frame.minX, target.anchorX <= frame.maxX {
            let inset = min(metrics.arrowInset, width / 2)
            arrow = BarPlacement.Arrow(
                edge: side == .above ? .below : .above,
                x: clamp(target.anchorX - frame.minX, lower: inset, upper: width - inset)
            )
        }

        return BarPlacement(screen: screen.id, frame: frame, side: side, arrow: arrow, itemsThatFit: itemsThatFit)
    }

    // MARK: What the bar is placed against

    private struct Target {
        /// The rectangle the bar sits above or below.
        var rect: CGRect
        /// Where the arrow points, horizontally.
        var anchorX: CGFloat
        var side: BarSide
    }

    /// BAR-3, in one place:
    ///
    /// - a single-line selection follows the user's Position preference and is centred on the selection;
    /// - a selection over several lines goes below the pointer if the drag went down, and above the
    ///   selection if it went up, which is the rule that keeps the bar out of the text the user just made;
    /// - with no bounds — the app would not say, or the route has no selection at all — the pointer is
    ///   both the rectangle and the centre;
    /// - with no drag direction either, which is the shortcut and the scripting routes, the preference
    ///   decides, because there is no gesture whose direction could.
    private static func target(for anchor: BarAnchor, preference: BarPosition, metrics: BarMetrics) -> Target {
        let preferred = BarSide(preference)

        guard let bounds = anchor.bounds else {
            let point = anchor.pointer ?? .zero
            return Target(rect: CGRect(origin: point, size: .zero), anchorX: point.x, side: preferred)
        }

        let isSingleLine = bounds.height <= metrics.singleLineMaximumHeight
        guard !isSingleLine, let direction = anchor.dragDirection else {
            return Target(rect: bounds, anchorX: bounds.midX, side: preferred)
        }

        switch direction {
        case .downwards:
            // Below the pointer, which is where the drag finished and where the user is looking.
            guard let pointer = anchor.pointer else {
                return Target(rect: bounds, anchorX: bounds.midX, side: .below)
            }
            return Target(rect: CGRect(origin: pointer, size: .zero), anchorX: pointer.x, side: .below)
        case .upwards:
            return Target(rect: bounds, anchorX: bounds.midX, side: .above)
        }
    }

    // MARK: Arithmetic

    private static func origin(onSide side: BarSide, of rect: CGRect, height: CGFloat, metrics: BarMetrics) -> CGFloat {
        let gap = metrics.anchorGap + metrics.arrowHeight
        switch side {
        case .above: return rect.minY - gap - height
        case .below: return rect.maxY + gap
        }
    }

    private static func fits(y: CGFloat, height: CGFloat, in visible: CGRect, metrics: BarMetrics) -> Bool {
        y >= visible.minY + metrics.screenMargin && y + height <= visible.maxY - metrics.screenMargin
    }

    private static func count(of widths: [CGFloat], fittingIn width: CGFloat, metrics: BarMetrics) -> Int {
        var used = metrics.horizontalPadding * 2
        var fitted = 0
        for itemWidth in widths {
            let next = used + itemWidth + (fitted == 0 ? 0 : metrics.itemSpacing)
            if next > width, fitted > 0 { break }
            used = next
            fitted += 1
        }
        return fitted
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}

extension CGRect {
    var isEmptyOrNull: Bool { isNull || isEmpty }
}
