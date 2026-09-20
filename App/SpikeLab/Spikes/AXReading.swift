import AppKit
import ApplicationServices
import CryptoKit
import PappuHarness

/// What one attempt to read the selection got back.
///
/// Length and digest only. The text is the operator's and never goes in a result file; the digest is
/// enough to tell whether two strategies read the same thing.
struct SelectionRead: Sendable {
    enum Outcome: String, Sendable {
        case text
        /// The calls worked and the selection is empty, which is an answer and not a failure.
        case empty
        /// No focused element, or it does not have the attribute.
        case unsupported
        /// `kAXErrorCannotComplete`: the app did not answer inside the messaging timeout.
        case timedOut
        case failed
    }

    var outcome: Outcome
    var length = 0
    var digest: String?
    var hasBounds = false
    var detail = ""
    var elapsed: Duration = .zero

    var gotText: Bool { outcome == .text }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    init(outcome: Outcome, detail: String = "") {
        self.outcome = outcome
        self.detail = detail
    }

    init(text: String, hasBounds: Bool, detail: String = "") {
        outcome = text.isEmpty ? .empty : .text
        length = text.count
        digest = text.isEmpty ? nil : Self.digest(of: text)
        self.hasBounds = hasBounds
        self.detail = detail
    }

    init(error: AXError, at call: String) {
        switch error {
        case .cannotComplete: outcome = .timedOut
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue: outcome = .unsupported
        default: outcome = .failed
        }
        detail = "\(call): AXError \(error.rawValue)"
    }
}

/// The app under test, fixed at the start of a run so every sample describes the same process.
struct SourceApp: Sendable {
    var pid: pid_t
    var bundleID: String
    var launchDate: Date?
    /// The matrix entry, when the app is one the PRD lists.
    var matrixApp: AppMatrix.App?

    var name: String { matrixApp?.name ?? bundleID }
    var family: String { matrixApp?.family ?? "unlisted" }

    var labels: [String: String] {
        ["app": name, "family": family, "tier": matrixApp?.tier.rawValue ?? "unlisted"]
    }

    /// Nil when SpikeLab itself is frontmost.
    @MainActor
    static func frontmost() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let bundleID = app.bundleIdentifier ?? "unknown"
        let matrixApp = (try? AppMatrix.bundled())?.apps.first { $0.bundleIDs.contains(bundleID) }
        return SourceApp(pid: app.processIdentifier, bundleID: bundleID, launchDate: app.launchDate, matrixApp: matrixApp)
    }
}

/// The two attributes that switch on an accessibility tree that is off by default (architecture §4.5, strategy 3).
enum AXEnableAttribute: String, Sendable, CaseIterable {
    /// Electron's own switch, meant for tools like this one.
    case manualAccessibility = "AXManualAccessibility"
    /// What VoiceOver sets. Chromium honours it; AppKit apps change window behaviour under it.
    case enhancedUserInterface = "AXEnhancedUserInterface"

    /// The attribute to try first for an app family of the matrix. Nil where enabling is not expected to help.
    static func preferred(forFamily family: String) -> AXEnableAttribute? {
        switch family {
        case "electron": .manualAccessibility
        case "chromium": .enhancedUserInterface
        default: nil
        }
    }
}

/// Accessibility reads against one app, for strategies 1–3. Not main-actor: AX calls block on the
/// target app, and the product makes them on a serial executor of their own (architecture §4.5).
///
/// One instance belongs to the thread that made it.
final class AXReader {
    /// How far above the focused element to look for one that has text-marker attributes.
    static let markerSearchDepth = 6

    let app: AXUIElement
    private let timeout: Float

    /// - Parameter timeout: Seconds before a call gives up. The product takes this from the stage
    ///   budget. A spike wants the real distribution, so it passes something generous and counts the
    ///   samples that were over budget afterwards; a tight timeout would hide how late they were.
    init(pid: pid_t, timeout: Float = 1) {
        app = AXUIElementCreateApplication(pid)
        self.timeout = timeout
        AXUIElementSetMessagingTimeout(app, timeout)
    }

    // MARK: Strategy 1

    /// `AXSelectedText`, `AXSelectedTextRange` and `AXBoundsForRange` of the focused element.
    func readAttributes() -> SelectionRead {
        timed {
            let (element, error) = focusedElement()
            guard let element else { return SelectionRead(error: error, at: "focusedElement") }
            var value: CFTypeRef?
            let textError = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
            guard textError == .success, let text = value as? String else {
                return SelectionRead(error: textError == .success ? .noValue : textError, at: "selectedText")
            }
            guard !text.isEmpty else { return SelectionRead(text: text, hasBounds: false) }

            var range: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
                  let range
            else { return SelectionRead(text: text, hasBounds: false, detail: "no selectedTextRange") }
            let bounds = rect(of: element, kAXBoundsForRangeParameterizedAttribute, range)
            return SelectionRead(text: text, hasBounds: bounds != nil, detail: bounds == nil ? "no boundsForRange" : "")
        }
    }

    // MARK: Strategy 2

    /// WebKit's text-marker attributes. They are on the web area, which is the focused element or
    /// somewhere above it, so this walks up and says how far it had to go.
    func readTextMarkers() -> SelectionRead {
        timed {
            let (focused, error) = focusedElement()
            guard var element = focused else { return SelectionRead(error: error, at: "focusedElement") }
            var lastError = AXError.attributeUnsupported
            for depth in 0...Self.markerSearchDepth {
                var markers: CFTypeRef?
                lastError = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markers)
                if lastError == .success, let markers {
                    var value: CFTypeRef?
                    let stringError = AXUIElementCopyParameterizedAttributeValue(
                        element, "AXStringForTextMarkerRange" as CFString, markers, &value
                    )
                    guard stringError == .success, let text = value as? String else {
                        return SelectionRead(error: stringError == .success ? .noValue : stringError, at: "stringForTextMarkerRange")
                    }
                    let bounds = text.isEmpty ? nil : rect(of: element, "AXBoundsForTextMarkerRange", markers)
                    return SelectionRead(text: text, hasBounds: bounds != nil, detail: "depth \(depth)")
                }
                if lastError == .cannotComplete { break }
                guard let parent = copyElement(element, kAXParentAttribute) else { break }
                element = parent
            }
            return SelectionRead(error: lastError, at: "selectedTextMarkerRange")
        }
    }

    /// Strategies 1 then 2, stopping at the first text, the way the chain does.
    func readChain() -> (read: SelectionRead, strategy: String) {
        let start = ContinuousClock.now
        var read = readAttributes()
        var strategy = "ax"
        if !read.gotText {
            let markers = readTextMarkers()
            if markers.gotText || read.outcome != .empty {
                read = markers
                strategy = "webkitMarkers"
            }
        }
        read.elapsed = start.duration(to: .now)
        return (read, strategy)
    }

    // MARK: Strategy 3

    /// Nil when the attribute cannot be read, which is common for `AXManualAccessibility`.
    func isEnabled(_ attribute: AXEnableAttribute) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute.rawValue as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    @discardableResult
    func set(_ attribute: AXEnableAttribute, to enabled: Bool) -> AXError {
        // A Boolean NSNumber is the same object as kCFBooleanTrue or kCFBooleanFalse, which Swift 6 sees as unsafe shared state.
        AXUIElementSetAttributeValue(app, attribute.rawValue as CFString, NSNumber(value: enabled))
    }

    /// Reads with the chain every `interval` until text comes back or `limit` passes.
    /// - Returns: The time to the first text, or nil if there was none, and the last read either way.
    func pollForText(limit: Duration, interval: Duration = .milliseconds(5)) -> (elapsed: Duration?, last: SelectionRead, strategy: String) {
        let start = ContinuousClock.now
        var last = readChain()
        while !last.read.gotText, start.duration(to: .now) < limit {
            Thread.sleep(forTimeInterval: interval.milliseconds / 1_000)
            last = readChain()
        }
        return (last.read.gotText ? start.duration(to: .now) : nil, last.read, last.strategy)
    }

    // MARK: Windows

    /// The focused window's frame in AX coordinates, to notice a window that moves when its tree is switched on.
    func focusedWindowFrame() -> CGRect? {
        guard let window = copyElement(app, kAXFocusedWindowAttribute) else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    // MARK: Plumbing

    func focusedElement() -> (AXUIElement?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, error == .success ? .noValue : error)
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return (element, .success)
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func rect(of element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty else { return nil }
        return rect
    }

    private func timed(_ body: () -> SelectionRead) -> SelectionRead {
        let start = ContinuousClock.now
        var read = body()
        read.elapsed = start.duration(to: .now)
        return read
    }
}

/// Tallies reads of one strategy so a spike can say "28 of 30, p95 4.1 ms" in a finding.
struct ReadTally {
    private(set) var outcomes: [SelectionRead.Outcome: Int] = [:]
    private(set) var digests: Set<String> = []
    private(set) var withBounds = 0
    private(set) var total = 0
    private(set) var lastDetail = ""

    mutating func add(_ read: SelectionRead) {
        total += 1
        outcomes[read.outcome, default: 0] += 1
        if let digest = read.digest { digests.insert(digest) }
        if read.hasBounds { withBounds += 1 }
        if !read.detail.isEmpty { lastDetail = read.detail }
    }

    var texts: Int { outcomes[.text] ?? 0 }
    var alwaysText: Bool { total > 0 && texts == total }

    var summary: String {
        let parts = outcomes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
        return "\(parts.joined(separator: " ")) bounds=\(withBounds)/\(total)" + (lastDetail.isEmpty ? "" : " (\(lastDetail))")
    }
}
