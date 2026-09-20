import AppKit
import ApplicationServices
import CryptoKit

/// Runs `body` on the main thread from a spike's own thread and hands back the result.
func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
}

/// One panel configuration from the spike 1 matrix.
struct PanelConfiguration: Sendable {
    var levelName: String
    var level: NSWindow.Level
    var behaviourName: String
    var behaviour: NSWindow.CollectionBehavior

    var labels: [String: String] { ["level": levelName, "behaviour": behaviourName] }

    static let levels: [(String, NSWindow.Level)] = [
        ("floating", .floating), ("statusBar", .statusBar), ("popUpMenu", .popUpMenu), ("screenSaver", .screenSaver),
    ]

    static let behaviours: [(String, NSWindow.CollectionBehavior)] = [
        ("default", []),
        ("allSpaces", [.canJoinAllSpaces]),
        ("allSpaces+fullScreenAux", [.canJoinAllSpaces, .fullScreenAuxiliary]),
        ("moveToActive+fullScreenAux", [.moveToActiveSpace, .fullScreenAuxiliary]),
    ]

    static var matrix: [PanelConfiguration] {
        levels.flatMap { level in
            behaviours.map { PanelConfiguration(levelName: level.0, level: level.1, behaviourName: $0.0, behaviour: $0.1) }
        }
    }

    /// What architecture §7 writes down for the bar, at the level the matrix is expected to settle on.
    static let designDefault = PanelConfiguration(
        levelName: "popUpMenu", level: .popUpMenu,
        behaviourName: "allSpaces+fullScreenAux", behaviour: [.canJoinAllSpaces, .fullScreenAuxiliary]
    )
}

/// What the window server and AppKit say about a panel that was asked to show.
struct PanelSample: Sendable {
    var isVisible: Bool
    var isOnActiveSpace: Bool
    var occlusionVisible: Bool
    /// From `CGWindowListCopyWindowInfo`, which answers without Screen Recording access for our own windows.
    var windowServerOnScreen: Bool
    var isKey: Bool
    var appIsActive: Bool

    /// The best the machine can say. Whether a person could see it is for the operator's notes.
    var reportedShown: Bool { isVisible && isOnActiveSpace && occlusionVisible && windowServerOnScreen }

    var summary: String {
        "visible=\(isVisible) activeSpace=\(isOnActiveSpace) unoccluded=\(occlusionVisible) "
            + "windowServer=\(windowServerOnScreen) key=\(isKey) appActive=\(appIsActive)"
    }
}

/// Where keyboard focus is, as another process sees it through Accessibility.
///
/// Two views, because they can differ: the system-wide focus follows the keyboard, so it moves to a
/// panel of ours that is key, while the source app's own focused element is what a paste would land in.
struct FocusSample: Sendable, Equatable {
    var frontmostBundleID: String
    /// The app that owns the system-wide focused element.
    var systemFocusedAppPID: pid_t?
    /// The app the element fields below were read from: the pinned source app, else the frontmost app.
    var sourcePID: pid_t?
    var sourceIsActive: Bool?
    var focusedRole: String?
    /// Identity of the focused element for comparing samples. `CFHash` of the AXUIElement, which is
    /// stable for one element within a run.
    var focusedElementHash: UInt?
    /// Length and digest only. The text itself is the operator's and never goes in a result file.
    var selectionLength: Int?
    var selectionDigest: String?

    var summary: String {
        let systemFocus = systemFocusedAppPID.map { $0 == sourcePID ? "source" : $0 == getpid() ? "SpikeLab" : "other" } ?? "?"
        return "frontmost=\(frontmostBundleID) systemFocus=\(systemFocus) sourceActive=\(sourceIsActive.map(String.init) ?? "?") "
            + "sourceRole=\(focusedRole ?? "?") selection=\(selectionLength.map(String.init) ?? "unreadable")"
    }

    var systemFocusIsOurs: Bool { systemFocusedAppPID == getpid() }

    func sameElement(as other: FocusSample) -> Bool {
        sourcePID == other.sourcePID && focusedElementHash != nil && focusedElementHash == other.focusedElementHash
    }

    func sameSelection(as other: FocusSample) -> Bool {
        selectionLength != nil && selectionLength == other.selectionLength && selectionDigest == other.selectionDigest
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The AppKit side of spike 1. Lives on the main actor; the spike drives it through `onMain`.
@MainActor
final class PanelLab {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var keyMonitor: Any?
    private(set) var keyDownsSeen = 0
    private let systemWide = AXUIElementCreateSystemWide()
    private var pinnedSource: NSRunningApplication?

    init() {
        // A hung app must cost a sample, not the run.
        AXUIElementSetMessagingTimeout(systemWide, 1)
    }

    var activationPolicy: String {
        switch NSApp.activationPolicy() {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
    }

    // MARK: Panels

    /// Builds the panel once, the way the product will (architecture §7: "one pre-built NSPanel").
    func build(keyable: Bool) {
        tearDown()
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let rect = NSRect(x: 0, y: 0, width: 420, height: 64)
        let panel: NSPanel = keyable
            ? KeyablePanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            : NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = !keyable
        panel.backgroundColor = .systemOrange

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        label.textColor = .black
        label.alignment = .center
        label.frame = rect.insetBy(dx: 8, dy: 20)
        label.autoresizingMask = [.width]
        panel.contentView?.addSubview(label)

        if keyable {
            let field = NSTextField(frame: NSRect(x: 8, y: 4, width: rect.width - 16, height: 20))
            field.placeholderString = "palette prototype"
            panel.contentView?.addSubview(field)
            panel.initialFirstResponder = field
        }
        self.panel = panel
        self.label = label
    }

    func apply(_ configuration: PanelConfiguration, caption: String) {
        panel?.level = configuration.level
        panel?.collectionBehavior = configuration.behaviour
        label?.stringValue = caption
    }

    /// Puts the panel on the screen the pointer is on and returns how long AppKit took to return.
    /// That is the cost on our side of the render stage; when the pixels reach the glass is not visible to us.
    func show(makeKey: Bool) -> Duration {
        guard let panel else { return .zero }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let start = ContinuousClock.now
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height / 4))
        }
        panel.orderFrontRegardless()
        if makeKey { panel.makeKey() }
        return start.duration(to: .now)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func sample() -> PanelSample {
        guard let panel else {
            return PanelSample(
                isVisible: false, isOnActiveSpace: false, occlusionVisible: false,
                windowServerOnScreen: false, isKey: false, appIsActive: NSApp.isActive
            )
        }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[CFString: Any]]
        let onScreen = info?.first?[kCGWindowIsOnscreen] as? Bool ?? false
        return PanelSample(
            isVisible: panel.isVisible, isOnActiveSpace: panel.isOnActiveSpace,
            occlusionVisible: panel.occlusionState.contains(.visible),
            windowServerOnScreen: onScreen, isKey: panel.isKeyWindow, appIsActive: NSApp.isActive
        )
    }

    func tearDown() {
        stopCountingKeys()
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }

    // MARK: Keys

    /// Counts key-downs AppKit delivers to us, which is what "the palette has the keyboard" means.
    func startCountingKeys(keyCode: UInt16) {
        keyDownsSeen = 0
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == keyCode else { return event }
            MainActor.assumeIsolated { self?.keyDownsSeen += 1 }
            return nil
        }
    }

    func stopCountingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Context and focus

    /// Whether some normal window of the frontmost app covers a whole screen: the nearest thing to
    /// "a fullscreen app is in front" that needs no permission. The operator's state note is the authority.
    func frontmostWindowCoversAScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
              as? [[CFString: Any]]
        else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return windows.contains { window in
            guard window[kCGWindowOwnerPID] as? pid_t == pid, window[kCGWindowLayer] as? Int == 0,
                  let bounds = window[kCGWindowBounds] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return screenSizes.contains { $0.width == width && $0.height == height }
        }
    }

    /// Fixes the frontmost app as the source, so later samples keep describing it even if focus moves to us.
    /// Returns false when we are frontmost ourselves.
    func pinSource() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
        pinnedSource = app
        return true
    }

    func focus() -> FocusSample {
        var sample = FocusSample(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
        let source = pinnedSource ?? NSWorkspace.shared.frontmostApplication
        sample.sourcePID = source?.processIdentifier
        sample.sourceIsActive = source?.isActive
        guard AXIsProcessTrusted(), let source else { return sample }

        if let app = copyElement(systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success { sample.systemFocusedAppPID = pid }
        }
        let sourceApp = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(sourceApp, 1)
        guard let element = copyElement(sourceApp, kAXFocusedUIElementAttribute) else { return sample }
        AXUIElementSetMessagingTimeout(element, 1)
        sample.focusedElementHash = CFHash(element)
        sample.focusedRole = copyValue(element, kAXRoleAttribute) as? String
        if let text = copyValue(element, kAXSelectedTextAttribute) as? String {
            sample.selectionLength = text.count
            sample.selectionDigest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        return sample
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

extension FocusSample {
    init(frontmostBundleID: String) {
        self.init(
            frontmostBundleID: frontmostBundleID, systemFocusedAppPID: nil, sourcePID: nil, sourceIsActive: nil,
            focusedRole: nil, focusedElementHash: nil, selectionLength: nil, selectionDigest: nil
        )
    }
}
