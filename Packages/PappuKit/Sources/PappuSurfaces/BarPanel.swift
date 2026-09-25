import AppKit
import CoreGraphics
import PappuSelection

/// The bar's window (architecture §7, BAR-1, BAR-2).
///
/// `canBecomeKey` is `false` and there is no setting that changes it. Everything else about the panel
/// is read off a `BarPanelConfiguration`, which is a value so that a test can assert what the panel
/// will be without a window server; this is the one place that turns that value into AppKit.
public final class BarPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

extension BarWindowLevel {
    var appKit: NSWindow.Level {
        switch self {
        case .floating: .floating
        case .statusBar: .statusBar
        case .popUpMenu: .popUpMenu
        case .screenSaver: .screenSaver
        }
    }
}

// MARK: - Type

/// The fonts the bar draws with, in one place, because the measurer and the button have to agree: a
/// width measured with one font and drawn with another is a bar that clips its own labels.
enum BarType {
    static var label: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var letters: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static let symbolPointSize: CGFloat = 15

    static func width(of text: String, in font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// AppKit's answer to "how wide is that button".
///
/// It is a seam and not a free function because every placement test would otherwise need a text
/// system: a test says `[40, 40, 40]` and gets to assert what the layout does with it.
public struct BarItemMeasurer: BarMeasuring {
    /// An icon button is square, inside the bar's own height.
    public var iconPadding: CGFloat = 6
    /// A text button gets room either side of its words.
    public var textPadding: CGFloat = 9
    public var minimumWidth: CGFloat = 24

    public init() {}

    public func widths(for content: BarContent, metrics: BarMetrics) -> [CGFloat] {
        let square = metrics.height - iconPadding
        return content.items.map { item in
            switch item.display {
            case .icon(.symbol), .icon(.image):
                return max(minimumWidth, square)
            case .icon(.letters(let letters)):
                return max(minimumWidth, BarType.width(of: letters, in: BarType.letters) + textPadding * 2)
            case .text(let text):
                return max(minimumWidth, BarType.width(of: text, in: BarType.label) + textPadding * 2)
            }
        }
    }

    public func width(ofResult text: String, metrics: BarMetrics) -> CGFloat {
        max(minimumWidth, BarType.width(of: BarFeedbackView.oneLine(text), in: BarType.label) + textPadding * 2)
    }
}

// MARK: - The shape

/// The bar's outline: a rounded rectangle with a triangle growing out of one edge.
///
/// In the root view's own coordinates, which are flipped so that they run the same way as everything
/// else in this module — y downwards.
enum BarShape {
    static func path(body: CGRect, arrow: BarPlacement.Arrow?, metrics: BarMetrics) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: metrics.cornerRadius, cornerHeight: metrics.cornerRadius)
        guard let arrow else { return path }

        let half = metrics.arrowWidth / 2
        let x = body.minX + arrow.x
        // A point of overlap with the body, so the join does not show as a hairline.
        switch arrow.edge {
        case .below:
            let base = body.maxY - 1
            path.move(to: CGPoint(x: x - half, y: base))
            path.addLine(to: CGPoint(x: x, y: body.maxY + metrics.arrowHeight))
            path.addLine(to: CGPoint(x: x + half, y: base))
        case .above:
            let base = body.minY + 1
            path.move(to: CGPoint(x: x - half, y: base))
            path.addLine(to: CGPoint(x: x, y: body.minY - metrics.arrowHeight))
            path.addLine(to: CGPoint(x: x + half, y: base))
        }
        path.closeSubpath()
        return path
    }
}

/// The root of the bar's view tree. Flipped, and transparent outside the bar's own outline so that a
/// click in the empty corners beside the arrow goes to whatever is underneath.
final class BarRootView: NSView {
    var shape: CGPath?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let shape, shape.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// What sits behind the buttons when vibrancy is off: Reduce Transparency, Increase Contrast, or a
/// colour mode the user pinned (BAR-8a, BAR-14).
final class BarSolidView: NSView {
    var barAppearance: BarAppearance = .resolve(SystemAppearanceSettings(), preference: .system)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colour: NSColor = barAppearance.colorMode == .dark
            ? NSColor(calibratedWhite: 0.14, alpha: 1)
            : NSColor(calibratedWhite: 0.97, alpha: 1)
        colour.setFill()
        bounds.fill()
    }
}

// MARK: - A button

/// One button on the bar (BAR-6, BAR-11, BAR-14).
final class BarButtonView: NSView {
    let item: BarItem
    var metrics: BarMetrics
    var barAppearance: BarAppearance
    var onPress: ((BarItemID, PointerEvent.Modifiers) -> Void)?

    var isHighlighted = false { didSet { refresh() } }
    private var isHovered = false { didSet { refresh() } }
    private var isPressed = false { didSet { refresh() } }

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(item: BarItem, metrics: BarMetrics, appearance: BarAppearance) {
        self.item = item
        self.metrics = metrics
        self.barAppearance = appearance
        super.init(frame: .zero)

        wantsLayer = true
        toolTip = item.tooltip
        addSubview(imageView)
        addSubview(label)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        switch item.display {
        case .icon(.symbol(let name)):
            let configuration = NSImage.SymbolConfiguration(pointSize: BarType.symbolPointSize, weight: .regular)
            // A manifest may name a symbol this macOS does not have; the action's initials are a
            // better button than an empty one (BAR-6).
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: item.name)?
                .withSymbolConfiguration(configuration) {
                image.isTemplate = true
                imageView.image = image
                label.isHidden = true
            } else {
                label.stringValue = Self.initials(of: item.name)
                label.font = BarType.letters
                imageView.isHidden = true
            }
        case .icon(.letters(let letters)):
            label.stringValue = letters
            label.font = BarType.letters
            imageView.isHidden = true
        case .icon(.image(let file, let isTemplate)):
            // A package whose icon file is missing or unreadable gets the same fallback as an unknown
            // symbol: the action's initials.
            if let image = NSImage(contentsOf: file) {
                image.isTemplate = isTemplate
                image.size = NSSize(width: BarType.symbolPointSize * 1.3, height: BarType.symbolPointSize * 1.3)
                imageView.image = image
                imageView.imageScaling = .scaleNone
                label.isHidden = true
            } else {
                label.stringValue = Self.initials(of: item.name)
                label.font = BarType.letters
                imageView.isHidden = true
            }
        case .text(let text):
            label.stringValue = text
            label.font = BarType.label
            imageView.isHidden = true
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.tooltip)
        setAccessibilityEnabled(item.isEnabled)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// PappuClip is never the active app, so every click on the bar is a first mouse. Without this the
    /// first one would only activate us — and we do not activate (BAR-1).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let height = label.intrinsicContentSize.height
        let inset: CGFloat = 8
        label.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - inset * 2), height: height)
    }

    /// A result as the bar shows it: its line breaks and tabs become spaces, because the bar has one
    /// line and a newline in a one-line label shows as nothing at all.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard item.isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(item.id, PointerEvent.Modifiers(event.modifierFlags))
    }

    override func accessibilityPerformPress() -> Bool {
        guard item.isEnabled else { return false }
        onPress?(item.id, [])
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isLit else { return }
        let radius = metrics.cornerRadius - 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        highlightColour.setFill()
        bounds.fill()
    }

    private var isLit: Bool { item.isEnabled && (isHighlighted || isHovered || isPressed) }

    private var highlightColour: NSColor {
        let base: NSColor = barAppearance.highlight == .contrast ? .labelColor : .controlAccentColor
        return isPressed ? base.blended(withFraction: 0.2, of: .black) ?? base : base
    }

    private var foreground: NSColor {
        guard item.isEnabled else { return .tertiaryLabelColor }
        guard isLit else { return .labelColor }
        return barAppearance.highlight == .contrast ? .textBackgroundColor : .white
    }

    private func refresh() {
        imageView.contentTintColor = foreground
        label.textColor = foreground
        setAccessibilityHelp(item.tooltip)
        needsDisplay = true
    }

    private static func initials(of name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: - Feedback

/// BAR-12a's one view: the spinner, the word, the tick and the cross, in the bar's own place.
final class BarFeedbackView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        label.alignment = .center
        label.font = BarType.label
        // A result is one line, cut at its end, whatever width the bar could be given (BAR-12b).
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        symbol.imageScaling = .scaleProportionallyUpOrDown
        [spinner, label, symbol].forEach(addSubview)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = min(bounds.height - 8, 16)
        spinner.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        symbol.frame = spinner.frame
        let height = label.intrinsicContentSize.height
        let inset: CGFloat = 8
        label.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - inset * 2), height: height)
    }

    /// A result as the bar shows it: its line breaks and tabs become spaces, because the bar has one
    /// line and a newline in a one-line label shows as nothing at all.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func present(_ state: BarFeedbackState, motion: BarMotion, appearance: BarAppearance) {
        spinner.stopAnimation(nil)
        [spinner, label, symbol].forEach { $0.isHidden = true }
        label.toolTip = nil
        layer?.removeAllAnimations()

        switch state {
        case .idle:
            isHidden = true
            return
        case .running:
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .copied:
            label.isHidden = false
            label.stringValue = BarStrings.feedbackCopied
            label.textColor = .labelColor
        case .result(let text):
            label.isHidden = false
            label.stringValue = Self.oneLine(text)
            label.textColor = .labelColor
            label.toolTip = text
        case .message(let text):
            label.isHidden = false
            label.stringValue = Self.oneLine(text)
            label.textColor = .secondaryLabelColor
            label.toolTip = text
        case .succeeded:
            symbol.isHidden = false
            symbol.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: BarStrings.feedbackSucceeded)
            symbol.contentTintColor = .labelColor
        case .failed:
            symbol.isHidden = false
            symbol.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: BarStrings.feedbackFailed
            )
            symbol.contentTintColor = .systemRed
        }
        isHidden = false
        needsLayout = true
        // Reduce Motion takes the shake and leaves the spinner: one of them is decoration and the
        // other is the only sign that work is still going on (BAR-14).
        if motion == .shake { shake() }
    }

    private func shake() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        let centre = layer?.position.x ?? 0
        shake.values = [0, -5, 5, -3, 3, 0].map { centre + $0 }
        shake.duration = 0.3
        layer?.add(shake, forKey: "bar.shake")
    }
}

// MARK: - The window

/// The one implementation of `BarWindowing`: a pre-built panel, moved and filled rather than made
/// (PRD §11.1). Everything it is asked to do has already been decided next door.
@MainActor
public final class BarWindow: BarWindowing {
    public weak var events: (any BarWindowEvents)?

    private let configuration: BarPanelConfiguration
    private let measurer: BarItemMeasurer

    private var panel: BarPanel?
    private var root: BarRootView?
    private var backdrop: NSVisualEffectView?
    private var solid: BarSolidView?
    private var host: NSView?
    private var feedback: BarFeedbackView?
    private var buttons: [BarButtonView] = []
    private var barFrame: CGRect = .null

    public init(configuration: BarPanelConfiguration = .bar, measurer: BarItemMeasurer = BarItemMeasurer()) {
        self.configuration = configuration
        self.measurer = measurer
    }

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var frame: CGRect { barFrame }

    public func prepare() {
        guard panel == nil else { return }

        var style: NSWindow.StyleMask = configuration.isBorderless ? [.borderless] : []
        if configuration.isNonActivating { style.insert(.nonactivatingPanel) }
        let panel = BarPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: style, backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = configuration.hidesOnDeactivate
        panel.level = configuration.level.appKit
        panel.ignoresMouseEvents = false
        panel.setAccessibilityLabel(BarStrings.barLabel)
        // Borderless panels are left out of the accessibility hierarchy unless they say otherwise.
        panel.setAccessibilityRole(.group)
        var behaviour: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if configuration.joinsAllSpaces { behaviour.insert(.canJoinAllSpaces) }
        if configuration.isFullScreenAuxiliary { behaviour.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behaviour

        let root = BarRootView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
        let backdrop = NSVisualEffectView(frame: root.bounds)
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        let solid = BarSolidView(frame: root.bounds)
        solid.wantsLayer = true
        solid.isHidden = true
        let host = NSView(frame: root.bounds)
        host.wantsLayer = true
        let feedback = BarFeedbackView(frame: root.bounds)
        feedback.isHidden = true

        [backdrop, solid, host, feedback].forEach(root.addSubview)
        panel.contentView = root

        (self.panel, self.root, self.backdrop, self.solid, self.host, self.feedback) =
            (panel, root, backdrop, solid, host, feedback)
    }

    public func show(_ content: BarContent, placement: BarPlacement, appearance: BarAppearance, metrics: BarMetrics) {
        prepare()
        guard let panel, let root, let backdrop, let solid, let host, let feedback else { return }

        let window = placement.windowFrame(metrics: metrics)
        barFrame = window
        panel.setFrame(BarScreen.flipped(window, inMainDisplayHeight: Self.mainDisplayHeight), display: false)

        // The body sits below the arrow when the arrow is on top, and at the origin otherwise.
        let arrowAbove = placement.arrow?.edge == .above
        let body = CGRect(
            x: 0,
            y: arrowAbove ? metrics.arrowHeight : 0,
            width: placement.frame.width,
            height: placement.frame.height
        )
        root.frame = CGRect(origin: .zero, size: window.size)
        let shape = BarShape.path(body: body, arrow: placement.arrow, metrics: metrics)
        root.shape = shape

        let vibrant = appearance.background == .vibrancy
        backdrop.isHidden = !vibrant
        solid.isHidden = vibrant
        solid.barAppearance = appearance
        for view in [backdrop as NSView, solid, host, feedback] {
            view.frame = root.bounds
        }
        for view in [backdrop as NSView, solid] {
            let mask = CAShapeLayer()
            mask.path = shape
            view.layer?.mask = mask
        }
        solid.needsDisplay = true
        panel.appearance = NSAppearance(named: appearance.colorMode == .dark ? .darkAqua : .aqua)
        root.layer?.borderWidth = appearance.border == .contrast ? 1 : 0
        root.layer?.borderColor = NSColor.labelColor.cgColor

        layOut(content, in: body, host: host, appearance: appearance, metrics: metrics)
        feedback.frame = body
        feedback.present(.idle, motion: .none, appearance: appearance)
        host.isHidden = false

        // `orderFrontRegardless` rather than `orderFront`: PappuClip is an accessory app and is never
        // the active one, so an ordinary order-front would do nothing (BAR-1, BAR-2).
        panel.orderFrontRegardless()
    }

    private func layOut(
        _ content: BarContent,
        in body: CGRect,
        host: NSView,
        appearance: BarAppearance,
        metrics: BarMetrics
    ) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []

        let widths = measurer.widths(for: content, metrics: metrics)
        var x = body.minX + metrics.horizontalPadding
        for (item, width) in zip(content.items, widths) {
            let button = BarButtonView(item: item, metrics: metrics, appearance: appearance)
            button.frame = CGRect(x: x, y: body.minY + 2, width: width, height: body.height - 4)
            button.onPress = { [weak self] id, modifiers in
                self?.events?.barPressed(id, modifiers: modifiers)
            }
            host.addSubview(button)
            buttons.append(button)
            x += width + metrics.itemSpacing
        }
        host.setAccessibilityLabel(BarStrings.barLabel)
    }

    public func highlight(_ index: Int?) {
        for (position, button) in buttons.enumerated() {
            button.isHighlighted = position == index
        }
    }

    public func present(_ state: BarFeedbackState, motion: BarMotion) {
        guard let feedback, let panel else { return }
        let appearance = BarAppearance.resolve(
            AppKitAppearance.settings(for: panel.effectiveAppearance),
            preference: .system
        )
        feedback.present(state, motion: motion, appearance: appearance)
        host?.isHidden = state != .idle
    }

    public func announce(_ message: String) {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    public func hide() {
        panel?.orderOut(nil)
        highlight(nil)
        feedback?.present(.idle, motion: .none, appearance: .resolve(SystemAppearanceSettings(), preference: .system))
        host?.isHidden = false
        barFrame = .null
    }

    /// AppKit measures from the bottom of the display holding the menu bar, which `NSScreen.screens`
    /// puts first. This is the only number the module's one coordinate conversion needs.
    static var mainDisplayHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

// MARK: - The system, read

/// The displays, in this module's coordinates.
public struct AppKitScreens: BarScreenSource {
    public init() {}

    public func screens() -> [BarScreen] {
        // The only caller is `BarController`, which is on the main actor, as `NSScreen` is.
        MainActor.assumeIsolated {
            let height = BarWindow.mainDisplayHeight
            return NSScreen.screens.enumerated().map { index, screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return BarScreen(
                    id: number?.intValue ?? index,
                    frame: BarScreen.flipped(screen.frame, inMainDisplayHeight: height),
                    visibleFrame: BarScreen.flipped(screen.visibleFrame, inMainDisplayHeight: height)
                )
            }
        }
    }
}

/// Dark mode and the three accessibility settings the bar honours (BAR-8a, BAR-14).
public struct AppKitAppearance: SystemAppearanceReading {
    public init() {}

    public func currentAppearance() -> SystemAppearanceSettings {
        MainActor.assumeIsolated {
            Self.settings(for: NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
        }
    }

    static func settings(for appearance: NSAppearance) -> SystemAppearanceSettings {
        let workspace = NSWorkspace.shared
        return SystemAppearanceSettings(
            isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}
