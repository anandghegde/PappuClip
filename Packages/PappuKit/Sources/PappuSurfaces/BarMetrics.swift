import CoreGraphics

/// Every size the bar is laid out from, in one value.
///
/// It is data rather than constants so that BAR-8b's size slider (M4) scales one thing, and so that
/// `BarLayout`'s tests can state a geometry instead of inheriting one.
public struct BarMetrics: Sendable, Equatable {
    /// The bar's height, excluding the callout arrow.
    public var height: CGFloat
    /// Between the bar's edge and the first button.
    public var horizontalPadding: CGFloat
    public var itemSpacing: CGFloat
    public var cornerRadius: CGFloat
    public var arrowWidth: CGFloat
    public var arrowHeight: CGFloat
    /// Between the bar (arrow tip included) and the thing it points at.
    public var anchorGap: CGFloat
    /// How close to the edge of the visible frame the bar may come (BAR-2).
    public var screenMargin: CGFloat
    /// BAR-5a caps the width on very wide displays. Overflow into pages is M4; until then this is
    /// what stops a long action set from spanning a 6K display.
    public var maximumWidth: CGFloat
    /// A selection taller than this is treated as several lines, which is the branch BAR-3 places by
    /// drag direction rather than by the position preference.
    ///
    /// A heuristic, and knowingly one: the Accessibility tree gives the union of the selected
    /// rectangles and never a line count. Two lines of ordinary body text clear it and one line of a
    /// display heading does not, which is the trade the requirement's own wording invites. Spike 3's
    /// per-app runs are where a better rule would come from.
    public var singleLineMaximumHeight: CGFloat

    public init(
        height: CGFloat = 30,
        horizontalPadding: CGFloat = 4,
        itemSpacing: CGFloat = 1,
        cornerRadius: CGFloat = 6,
        arrowWidth: CGFloat = 12,
        arrowHeight: CGFloat = 6,
        anchorGap: CGFloat = 4,
        screenMargin: CGFloat = 6,
        maximumWidth: CGFloat = 900,
        singleLineMaximumHeight: CGFloat = 32
    ) {
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.itemSpacing = itemSpacing
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.anchorGap = anchorGap
        self.screenMargin = screenMargin
        self.maximumWidth = maximumWidth
        self.singleLineMaximumHeight = singleLineMaximumHeight
    }

    public static let standard = BarMetrics()

    /// The arrow may not sit over a rounded corner, so this is the nearest its centre may come to
    /// either end of the bar.
    public var arrowInset: CGFloat { cornerRadius + arrowWidth / 2 }

    /// The bar's own height plus the arrow's, which is what has to fit above or below the anchor.
    public var totalHeight: CGFloat { height + arrowHeight }

    /// The narrowest a bar can be: one button of nothing, padded.
    public var minimumWidth: CGFloat { horizontalPadding * 2 + arrowWidth + cornerRadius * 2 }

    /// The width of a bar holding buttons of these widths, before any clamping.
    public func width(forItemWidths widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return minimumWidth }
        let spacing = itemSpacing * CGFloat(widths.count - 1)
        return max(minimumWidth, horizontalPadding * 2 + widths.reduce(0, +) + spacing)
    }
}
