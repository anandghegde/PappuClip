import CoreGraphics
import PappuSelection
import Testing

/// Making a `CGEvent` needs no permission; only tapping or posting one does.
@Suite struct TapInputTests {
    static let ownTag = SyntheticEventTag(rawValue: 0x5041)!

    private func mouseEvent(_ type: CGEventType, x: Double = 320, y: Double = 240, button: CGMouseButton = .left) throws -> CGEvent {
        try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button))
    }

    @Test func aMouseEventIsCopiedOutWithItsFlagsClickCountAndWindow() throws {
        let event = try mouseEvent(.leftMouseUp)
        event.flags = [.maskShift, .maskCommand, .maskNumericPad]
        event.timestamp = 42_000
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 911)

        let expected = PointerEvent(
            kind: .up, location: CGPoint(x: 320, y: 240), modifiers: [.shift, .command], clickCount: 2,
            timestampNs: 42_000, windowNumber: 911
        )
        #expect(TapInput(type: .leftMouseUp, event: event, ownTag: Self.ownTag) == .pointer(expected))
    }

    @Test func eachPointerEventTypeHasItsKind() throws {
        let kinds: [(CGEventType, PointerEvent.Kind)] = [(.leftMouseDown, .down), (.leftMouseDragged, .dragged), (.leftMouseUp, .up)]
        for (type, kind) in kinds {
            guard case .pointer(let pointer) = TapInput(type: type, event: try mouseEvent(type), ownTag: Self.ownTag) else {
                Issue.record("\(type) was not read as a pointer event")
                continue
            }
            #expect(pointer.kind == kind)
        }
    }

    @Test func aScrollHasNoClickCount() throws {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0))
        guard case .pointer(let pointer) = TapInput(type: .scrollWheel, event: event, ownTag: Self.ownTag) else {
            Issue.record("a scroll was not read as a pointer event")
            return
        }
        #expect(pointer.kind == .scroll)
        #expect(pointer.clickCount == 0)
    }

    @Test func aKeyDownKeepsItsCodeModifiersAndRepeatFlag() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        event.flags = [.maskAlternate, .maskControl]
        event.timestamp = 7
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        let expected = KeyPress(keyCode: 53, modifiers: [.option, .control], isRepeat: true, timestampNs: 7)
        #expect(TapInput(type: .keyDown, event: event, ownTag: Self.ownTag) == .keyDown(expected))
    }

    // MARK: Architecture §3.4, events we post

    @Test func anEventPappuClipPostedBecomesNothing() throws {
        let copy = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        Self.ownTag.mark(copy)
        #expect(TapInput(type: .keyDown, event: copy, ownTag: Self.ownTag) == nil)

        let click = try mouseEvent(.leftMouseDown)
        Self.ownTag.mark(click)
        #expect(TapInput(type: .leftMouseDown, event: click, ownTag: Self.ownTag) == nil)
    }

    @Test func anEventSomeoneElseTaggedIsStillInput() throws {
        let event = try mouseEvent(.leftMouseDown)
        event.setIntegerValueField(.eventSourceUserData, value: 0x1234)
        #expect(TapInput(type: .leftMouseDown, event: event, ownTag: Self.ownTag) != nil)
    }

    @Test func aTagIsNeverZeroBecauseThatIsWhatAnUntaggedEventCarries() {
        #expect(SyntheticEventTag(rawValue: 0) == nil)
        for _ in 0..<100 { #expect(SyntheticEventTag.random().rawValue != 0) }
    }

    // MARK: ACT-15

    @Test func aDisabledNoticeIsReadFromTheTypeAlone() throws {
        // The event that comes with a notice is not a real one, so even our own tag on it changes nothing.
        let event = try mouseEvent(.leftMouseDown)
        Self.ownTag.mark(event)
        #expect(TapInput(type: .tapDisabledByTimeout, event: event, ownTag: Self.ownTag) == .disabled(.timeout))
        #expect(TapInput(type: .tapDisabledByUserInput, event: event, ownTag: Self.ownTag) == .disabled(.userInput))
    }

    @Test func eventsNoTapAsksForAreIgnored() throws {
        #expect(TapInput(type: .rightMouseDown, event: try mouseEvent(.rightMouseDown, button: .right), ownTag: Self.ownTag) == nil)
        #expect(TapInput(type: .mouseMoved, event: try mouseEvent(.mouseMoved), ownTag: Self.ownTag) == nil)
        let keyUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
        #expect(TapInput(type: .keyUp, event: keyUp, ownTag: Self.ownTag) == nil)
    }
}
