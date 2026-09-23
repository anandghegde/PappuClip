import CoreGraphics
import PappuSelection
import PappuSurfaces
import Testing

private let metrics = BarMetrics.standard
private let widths: [CGFloat] = [30, 30, 30]

private func place(
    bounds: CGRect? = nil,
    pointer: CGPoint? = nil,
    drag: DragDirection? = nil,
    preference: BarPosition = .aboveText,
    widths: [CGFloat] = widths,
    screens: [BarScreen] = [mainScreen]
) -> BarPlacement? {
    BarLayout.place(
        anchor: BarAnchor(bounds: bounds, pointer: pointer, dragDirection: drag),
        itemWidths: widths,
        preference: preference,
        metrics: metrics,
        screens: screens
    )
}

/// A single line of text in the middle of the main display.
private let line = CGRect(x: 600, y: 400, width: 200, height: 20)

/// BAR-2 and BAR-3: which display the bar lands on, which side of the selection it sits, and what
/// happens at the edges — all of it on display arrangements no single machine has.
@Suite struct BarLayoutTests {

    // MARK: The ordinary case

    @Test func aBarSitsAboveASingleLineSelectionAndIsCentredOnIt() throws {
        let placement = try #require(place(bounds: line))

        #expect(placement.side == .above)
        #expect(placement.frame == CGRect(x: 650, y: 360, width: 100, height: 30))
        #expect(placement.arrow?.edge == .below)
        #expect(placement.arrow?.x == 50)
        #expect(placement.itemsThatFit == 3)
    }

    @Test func thePositionPreferencePutsTheBarUnderTheSelection() throws {
        let placement = try #require(place(bounds: line, preference: .belowText))

        #expect(placement.side == .below)
        #expect(placement.frame.minY == line.maxY + metrics.anchorGap + metrics.arrowHeight)
        #expect(placement.arrow?.edge == .above)
    }

    @Test func theWindowIsTheBarPlusItsArrow() throws {
        let above = try #require(place(bounds: line))
        let below = try #require(place(bounds: line, preference: .belowText))

        #expect(above.windowFrame(metrics: metrics) == CGRect(x: 650, y: 360, width: 100, height: 36))
        #expect(below.windowFrame(metrics: metrics).minY == below.frame.minY - metrics.arrowHeight)
        #expect(below.windowFrame(metrics: metrics).height == metrics.totalHeight)
    }

    // MARK: Edges

    @Test func aBarWithNoRoomAboveFlipsBelow() throws {
        let placement = try #require(place(bounds: CGRect(x: 600, y: 30, width: 200, height: 20)))

        #expect(placement.side == .below)
        #expect(placement.frame.minY == 60)
        #expect(placement.arrow?.edge == .above)
    }

    @Test func aBarWithNoRoomBelowFlipsAbove() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 600, y: 860, width: 200, height: 20),
            preference: .belowText
        ))

        #expect(placement.side == .above)
        #expect(placement.frame.maxY <= mainScreen.visibleFrame.maxY - metrics.screenMargin)
    }

    @Test func aSelectionTallerThanTheDisplayStillGetsABarButNoArrow() throws {
        let placement = try #require(place(bounds: CGRect(x: 600, y: -200, width: 200, height: 1400)))

        #expect(placement.arrow == nil)
        #expect(mainScreen.visibleFrame.contains(placement.frame))
    }

    @Test func aBarIsClampedToTheLeftEdgeOfTheVisibleFrame() throws {
        let placement = try #require(place(bounds: CGRect(x: 0, y: 400, width: 60, height: 20)))

        #expect(placement.frame.minX == mainScreen.visibleFrame.minX + metrics.screenMargin)
        #expect(placement.arrow?.x == 24)
    }

    @Test func aBarIsClampedToTheRightEdgeOfTheVisibleFrame() throws {
        let placement = try #require(place(bounds: CGRect(x: 1380, y: 400, width: 60, height: 20)))

        #expect(placement.frame.maxX == mainScreen.visibleFrame.maxX - metrics.screenMargin)
    }

    @Test func theBarStaysOutOfTheMenuBar() throws {
        let placement = try #require(place(bounds: CGRect(x: 600, y: 10, width: 200, height: 4)))

        #expect(placement.frame.minY >= mainScreen.visibleFrame.minY + metrics.screenMargin)
    }

    // MARK: The arrow

    @Test func theArrowNeverSitsOnARoundedCorner() throws {
        let placement = try #require(place(bounds: CGRect(x: 0, y: 400, width: 20, height: 20)))

        #expect(placement.arrow?.x == metrics.arrowInset)
    }

    @Test func aBarClampedPastItsAnchorPointsAtNothing() throws {
        let placement = try #require(place(bounds: CGRect(x: 1436, y: 400, width: 4, height: 20)))

        #expect(placement.arrow == nil)
        #expect(placement.frame.maxX == mainScreen.visibleFrame.maxX - metrics.screenMargin)
    }

    // MARK: Two displays (BAR-2)

    @Test func aSelectionOnTheSecondDisplayPutsTheBarThere() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 1700, y: 300, width: 100, height: 20),
            screens: [mainScreen, rightScreen]
        ))

        #expect(placement.screen == rightScreen.id)
        #expect(rightScreen.visibleFrame.contains(placement.frame))
    }

    @Test func aSelectionStraddlingTwoDisplaysGoesToTheOneHoldingMostOfIt() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 1400, y: 300, width: 100, height: 20),
            screens: [mainScreen, rightScreen]
        ))

        #expect(placement.screen == rightScreen.id)
    }

    @Test func withNoBoundsTheBarFollowsThePointerOntoItsDisplay() throws {
        let placement = try #require(place(
            pointer: CGPoint(x: 1900, y: 500),
            screens: [mainScreen, rightScreen]
        ))

        #expect(placement.screen == rightScreen.id)
        #expect(placement.frame.midX == 1900)
    }

    @Test func withNoDisplaysAtAllThereIsNoPlacement() {
        #expect(place(bounds: line, screens: []) == nil)
    }

    // MARK: Multi-line selections (BAR-3)

    @Test func aMultiLineSelectionDraggedDownwardsPutsTheBarBelowThePointer() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 100, y: 200, width: 800, height: 200),
            pointer: CGPoint(x: 500, y: 395),
            drag: .downwards
        ))

        #expect(placement.side == .below)
        #expect(placement.frame.minY == 405)
        #expect(placement.frame.midX == 500)
    }

    @Test func aMultiLineSelectionDraggedUpwardsPutsTheBarAboveTheSelection() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 100, y: 200, width: 800, height: 200),
            pointer: CGPoint(x: 500, y: 205),
            drag: .upwards
        ))

        #expect(placement.side == .above)
        #expect(placement.frame.maxY == 190)
        #expect(placement.frame.midX == 500)
    }

    @Test func aMultiLineSelectionWithNoDragDirectionFallsBackToThePreference() throws {
        let tall = CGRect(x: 100, y: 200, width: 800, height: 200)
        let above = try #require(place(bounds: tall))
        let below = try #require(place(bounds: tall, preference: .belowText))

        #expect(above.side == .above)
        #expect(below.side == .below)
    }

    @Test func aSelectionOfASingleTallLineIsStillASingleLine() throws {
        let placement = try #require(place(
            bounds: CGRect(x: 600, y: 400, width: 200, height: metrics.singleLineMaximumHeight),
            pointer: CGPoint(x: 700, y: 420),
            drag: .downwards
        ))

        #expect(placement.side == .above)
        #expect(placement.frame.midX == 700)
    }

    // MARK: How much fits

    @Test func aBarOnANarrowDisplayShowsAsManyButtonsAsFit() throws {
        let narrow = BarScreen(
            id: 9,
            frame: CGRect(x: 0, y: 0, width: 60, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 60, height: 400)
        )
        let placement = try #require(place(
            bounds: CGRect(x: 10, y: 200, width: 40, height: 20),
            screens: [narrow]
        ))

        #expect(placement.frame.width == 48)
        #expect(placement.itemsThatFit == 1)
    }

    @Test func oneButtonAlwaysFitsHoweverNarrowTheDisplay() throws {
        let sliver = BarScreen(
            id: 9,
            frame: CGRect(x: 0, y: 0, width: 20, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 20, height: 400)
        )
        let placement = try #require(place(
            bounds: CGRect(x: 0, y: 200, width: 20, height: 20),
            screens: [sliver]
        ))

        #expect(placement.itemsThatFit == 1)
    }

    @Test func theBarNeverGrowsPastItsMaximumWidth() throws {
        let placement = try #require(place(bounds: line, widths: Array(repeating: 30, count: 40)))

        #expect(placement.frame.width == metrics.maximumWidth)
        #expect(placement.itemsThatFit < 40)
    }

    @Test func aBarWithNoButtonsIsStillTheMinimumWidth() throws {
        let placement = try #require(place(bounds: line, widths: []))

        #expect(placement.frame.width == metrics.minimumWidth)
        #expect(placement.itemsThatFit == 0)
    }

    // MARK: Coordinates

    @Test func flippingARectangleTwiceGivesItBack() {
        let rect = CGRect(x: 120, y: -300, width: 40, height: 18)
        let there = BarScreen.flipped(rect, inMainDisplayHeight: 900)

        #expect(BarScreen.flipped(there, inMainDisplayHeight: 900) == rect)
        #expect(there != rect)
    }

    @Test func aRectangleOnTheMainDisplayFlipsAboutItsHeight() {
        let topLeft = CGRect(x: 0, y: 0, width: 10, height: 10)

        #expect(BarScreen.flipped(topLeft, inMainDisplayHeight: 900) == CGRect(x: 0, y: 890, width: 10, height: 10))
    }

    // MARK: From a presentation

    @Test func anAnchorIsTakenStraightOffThePresentation() {
        let anchor = BarAnchor(presentation(
            bounds: line,
            pointer: CGPoint(x: 700, y: 410),
            drag: .upwards
        ))

        #expect(anchor.bounds == line)
        #expect(anchor.pointer == CGPoint(x: 700, y: 410))
        #expect(anchor.dragDirection == .upwards)
    }
}
