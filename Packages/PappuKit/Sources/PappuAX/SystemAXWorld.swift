import ApplicationServices
import CoreGraphics
import Foundation

/// The Accessibility API itself (architecture §4.5).
///
/// Every Core Foundation type in the selection path is confined to this file: above it there are only
/// `AXElement` handles and `AXAttributeValue` cases. Nothing here is called off `AXActor`.
public struct SystemAXWorld: AXWorld {
    public init() {}

    /// `AXUIElementCreateApplication` talks to nothing; it wraps a pid. Making one per call is cheaper
    /// than keeping a cache that a relaunched app under a reused pid could make wrong.
    public func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    /// A timeout of zero means "use the global default" to AX, which is generous enough to hand a wedged
    /// app our queue for seconds, so callers clamp before they get here. Timeouts are per element, which
    /// is why a freshly copied element is given one too.
    /// `CFEqual` on two `AXUIElement`s, which is how AX itself says two references are one element:
    /// same process, same internal identifier. It does not ask the app anything, so an element whose
    /// window has closed still compares equal to itself — staleness is a separate question, and
    /// `DestinationVerifier` asks it by reading an attribute afterwards.
    public func isSame(_ one: AXElement, as other: AXElement) -> Bool {
        guard let one = uiElement(one), let other = uiElement(other) else { return false }
        return CFEqual(one, other)
    }

    public func setMessagingTimeout(_ seconds: Float, on element: AXElement) {
        guard let element = uiElement(element) else { return }
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    public func element(at point: CGPoint, in application: AXElement) -> Result<AXElement, AXFault> {
        guard let application = uiElement(application) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        var found: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found)
        guard error == .success, let found else { return .failure(AXFault(error)) }
        return .success(AXElement(found))
    }

    public func attribute(_ attribute: AXAttribute, of element: AXElement) -> Result<AXAttributeValue, AXFault> {
        guard let element = uiElement(element) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        guard error == .success, let value else { return .failure(AXFault(error)) }
        guard let decoded = Self.decode(value) else { return .failure(.unsupported) }
        return .success(decoded)
    }

    public func isSettable(_ attribute: AXAttribute, of element: AXElement) -> Result<Bool, AXFault> {
        guard let element = uiElement(element) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute.rawValue as CFString, &settable)
        // An attribute the element does not have is not settable, which is an answer and not a fault:
        // a label has no `AXSelectedText` and is not editable, and that is the whole question here.
        if error == .attributeUnsupported || error == .noValue { return .success(false) }
        guard error == .success else { return .failure(AXFault(error)) }
        return .success(settable.boolValue)
    }

    public func supports(_ attribute: AXParameterizedAttribute, of element: AXElement) -> Result<Bool, AXFault> {
        guard let element = uiElement(element) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        var names: CFArray?
        let error = AXUIElementCopyParameterizedAttributeNames(element, &names)
        // Most of the Mac's controls offer none, and say so by this code rather than by an empty list.
        if error == .attributeUnsupported || error == .noValue { return .success(false) }
        guard error == .success, let names = names as? [String] else { return .failure(AXFault(error)) }
        return .success(names.contains(attribute.rawValue))
    }

    public func value(
        _ attribute: AXParameterizedAttribute,
        for range: AXTextRange,
        of element: AXElement
    ) -> Result<AXAttributeValue, AXFault> {
        guard let element = uiElement(element) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return .failure(.failed(AXError.illegalArgument.rawValue))
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, attribute.rawValue as CFString, parameter, &value
        )
        guard error == .success, let value else { return .failure(AXFault(error)) }
        guard let decoded = Self.decode(value) else { return .failure(.unsupported) }
        return .success(decoded)
    }

    /// `AXUIElementSetAttributeValue` with a `CFBoolean`, which is what both switches take. An app that
    /// has never heard of the attribute answers `attributeUnsupported`, and that is `.unsupported` and
    /// not a failure worth retrying: it is how every app that is not Chromium or Electron answers.
    public func setTree(_ which: AXTreeSwitch, to on: Bool, of application: AXElement) -> Result<Void, AXFault> {
        guard let application = uiElement(application) else {
            return .failure(.failed(AXError.illegalArgument.rawValue))
        }
        let error = AXUIElementSetAttributeValue(
            application, which.rawValue as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
        guard error == .success else { return .failure(AXFault(error)) }
        return .success(())
    }

    /// Decodes by what the value *is*, not by what the attribute usually returns: an app is free to
    /// answer `AXRole` with something that is not a string, and we would rather call that unsupported
    /// than crash on it.
    private static func decode(_ value: CFTypeRef) -> AXAttributeValue? {
        switch CFGetTypeID(value) {
        case AXUIElementGetTypeID():
            return .element(AXElement(value as! AXUIElement))
        case CFStringGetTypeID():
            return .string(value as! String)
        case CFBooleanGetTypeID():
            return .flag(CFBooleanGetValue((value as! CFBoolean)))
        case CFNumberGetTypeID():
            var number = 0
            guard CFNumberGetValue((value as! CFNumber), .nsIntegerType, &number) else { return nil }
            return .number(number)
        case CFURLGetTypeID():
            return .url(value as! URL)
        case CFArrayGetTypeID():
            // A heterogeneous array is not one we know how to carry, so it is unsupported rather than
            // silently the elements it happened to contain.
            guard let array = value as? [AXUIElement] else { return nil }
            return .elements(array.map(AXElement.init))
        case AXValueGetTypeID():
            let value = value as! AXValue
            switch AXValueGetType(value) {
            case .cfRange:
                var range = CFRange()
                guard AXValueGetValue(value, .cfRange, &range) else { return nil }
                return .range(AXTextRange(location: range.location, length: range.length))
            case .cgRect:
                // `AXBoundsForRange`. AX answers in screen coordinates with a top-left origin, which is
                // the space the bar is placed in, so nothing is converted on the way through.
                var rect = CGRect.zero
                guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
                return .rect(rect)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Nil for a handle from another world, which is a programming error rather than a state the app
    /// can reach: one reader holds one world.
    private func uiElement(_ element: AXElement) -> AXUIElement? {
        guard CFGetTypeID(element.handle) == AXUIElementGetTypeID() else { return nil }
        return (element.handle as! AXUIElement)
    }
}

extension AXFault {
    /// The mapping M0 spike 3's reader arrived at, which is where the meanings of these codes were
    /// learned against real apps. Public because `SystemAXObserver` maps the same codes from
    /// PappuSelection, on the other side of the seam.
    public init(_ error: AXError) {
        switch error {
        case .apiDisabled:
            self = .notPermitted
        case .cannotComplete:
            self = .timedOut
        case .invalidUIElement, .invalidUIElementObserver:
            self = .staleElement
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented:
            self = .unsupported
        default:
            self = .failed(error.rawValue)
        }
    }
}
