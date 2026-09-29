import AppKit

// JS-17, JS-18: the two panels as AppKit draws them. Functional, not polished (M4 week 2 has the
// TextKit 2 view and the finished layout). Every control has an accessibility label, the keyboard
// reaches every control, and Escape is Cancel or Close.
//
// Both are non-activating panels: PappuClip does not come to the front, so the app the text came from
// stays frontmost and the destination that Replace and Insert verify is still the one in front.

/// A panel that can take the keyboard without activating PappuClip, and hands Escape to its owner.
final class NativePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    static func make(size: NSSize, resizable: Bool) -> NativePanel {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        let panel = NativePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    /// Near the pointer, on its screen, and wholly on it.
    func place(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return center() }
        var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height - 24)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }
}

// MARK: - The rich result panel

/// Draws a `ResultPanelModel` and forwards its buttons to it. BAR-17: it does not take focus when it
/// appears; clicking into the text to select some does, without bringing PappuClip to the front.
@MainActor
public final class ResultPanelController: NSObject, NSWindowDelegate {
    private let model: ResultPanelModel
    private let panel: NativePanel
    private let textView = NSTextView()
    private let copyButton = NSButton()
    private let replaceButton = NSButton()
    private let insertButton = NSButton()
    private let closeButton = NSButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    /// Held while the panel is up; let go of when it closes.
    private var retained: ResultPanelController?

    public init(model: ResultPanelModel) {
        self.model = model
        panel = NativePanel.make(size: NSSize(width: 460, height: 320), resizable: true)
        super.init()
        build()
        model.onChange = { [weak self] in self?.update() }
        model.onClose = { [weak self] in self?.hide() }
    }

    /// Shows the panel without taking focus, and asks whether Replace and Insert can start enabled.
    public func show(near point: NSPoint = NSEvent.mouseLocation) {
        retained = self
        update()
        panel.place(near: point)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .windowCreated)
        Task { await model.refresh() }
    }

    private func build() {
        panel.title = model.title
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true
        panel.onEscape = { [weak self] in self?.run { await $0.close() } }
        panel.setAccessibilityLabel(model.title)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = model.format == .markdown
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textStorage?.setAttributedString(Self.attributed(model.text, format: model.format))
        textView.setAccessibilityLabel(PanelStrings.resultTextLabel)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configure(copyButton, PanelStrings.copy, help: PanelStrings.copyHelp) { await $0.copy() }
        configure(replaceButton, PanelStrings.replace, help: PanelStrings.replaceHelp) { await $0.replace() }
        configure(insertButton, PanelStrings.insert, help: PanelStrings.insertHelp) { await $0.insert() }
        configure(closeButton, PanelStrings.close, help: nil) { await $0.close() }

        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [copyButton, replaceButton, insertButton, spacer, status, closeButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [scroll, explanation, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        panel.contentView = content
    }

    private func configure(_ button: NSButton, _ title: String, help: String?, action: @escaping (ResultPanelModel) async -> Void) {
        button.title = title
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(title)
        button.toolTip = help
        if let help { button.setAccessibilityHelp(help) }
        button.target = self
        button.action = #selector(pressed(_:))
        actions[ObjectIdentifier(button)] = action
    }

    private var actions: [ObjectIdentifier: (ResultPanelModel) async -> Void] = [:]

    @objc private func pressed(_ sender: NSButton) {
        guard let action = actions[ObjectIdentifier(sender)] else { return }
        run(action)
    }

    private func run(_ action: @escaping (ResultPanelModel) async -> Void) {
        let model = model
        Task { await action(model) }
    }

    private func update() {
        copyButton.isEnabled = model.canCopy
        replaceButton.isEnabled = model.canWrite
        insertButton.isEnabled = model.canWrite
        closeButton.isEnabled = !model.isClosed
        let why = model.explanation ?? ""
        explanation.stringValue = why
        explanation.isHidden = why.isEmpty
        // RUN-2e: a disabled Replace or Insert says why, to the pointer and to VoiceOver.
        for button in [replaceButton, insertButton] {
            button.toolTip = model.canWrite ? (button === replaceButton ? PanelStrings.replaceHelp : PanelStrings.insertHelp) : why
            button.setAccessibilityHelp(button.toolTip)
        }
        let said = model.status ?? ""
        if status.stringValue != said, !said.isEmpty {
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [.announcement: said, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        status.stringValue = said
    }

    private func hide() {
        panel.delegate = nil
        panel.orderOut(nil)
        retained = nil
    }

    public func windowWillClose(_ notification: Notification) {
        run { await $0.close() }
    }

    /// Plain text as written; Markdown through `SafeMarkdown`, with its emphasis as fonts.
    static func attributed(_ text: String, format: PanelTextFormat) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.textColor]
        guard format == .markdown else { return NSAttributedString(string: text, attributes: base) }
        let rendered = SafeMarkdown.render(text)
        let result = NSMutableAttributedString()
        for run in rendered.runs {
            var font = body
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: body.pointSize, weight: .regular) }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            var attributes = base
            attributes[.font] = font
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(rendered[run.range].characters), attributes: attributes))
        }
        return result
    }
}

// MARK: - The prompt

/// Draws a `PromptPanelModel`: the label, the field, Submit and Cancel. It takes the keyboard when it
/// appears, because typing into it is what it is for; Return submits and Escape cancels.
@MainActor
public final class PromptPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let model: PromptPanelModel
    private let panel: NativePanel
    private let label: NSTextField
    private let field = NSTextField()
    private let submitButton = NSButton()
    private let cancelButton = NSButton()
    private var retained: PromptPanelController?

    public init(model: PromptPanelModel) {
        self.model = model
        label = NSTextField(wrappingLabelWithString: model.label)
        panel = NativePanel.make(size: NSSize(width: 380, height: 150), resizable: false)
        super.init()
        build()
        model.onClose = { [weak self] in self?.hide() }
    }

    public func show(near point: NSPoint = NSEvent.mouseLocation) {
        retained = self
        panel.place(near: point)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func build() {
        panel.title = PanelStrings.promptTitle
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.model.cancel() }
        panel.setAccessibilityLabel(model.label)

        field.stringValue = model.value
        field.placeholderString = model.placeholder
        field.delegate = self
        // JS-18: the field is named by its label, for VoiceOver as on screen.
        field.setAccessibilityLabel(model.label)
        field.setAccessibilityTitleUIElement(label)
        if !model.placeholder.isEmpty { field.setAccessibilityPlaceholderValue(model.placeholder) }

        let source = NSTextField(labelWithString: model.source.isEmpty ? "" : PanelStrings.promptSource(model.source))
        source.textColor = .secondaryLabelColor
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        source.isHidden = model.source.isEmpty

        submitButton.title = PanelStrings.submit
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        submitButton.setAccessibilityLabel(PanelStrings.submit)
        submitButton.target = self
        submitButton.action = #selector(submit)

        cancelButton.title = PanelStrings.cancel
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel(PanelStrings.cancel)
        cancelButton.setAccessibilityHelp(PanelStrings.cancelHelp)
        cancelButton.toolTip = PanelStrings.cancelHelp
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, submitButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [label, field, source, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
    }

    @objc private func submit() {
        model.value = field.stringValue
        model.submit()
    }

    @objc private func cancel() {
        model.cancel()
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.value = field.stringValue
    }

    private func hide() {
        panel.delegate = nil
        panel.orderOut(nil)
        retained = nil
    }

    /// The close button: the same as Cancel.
    public func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}
