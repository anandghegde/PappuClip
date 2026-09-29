import Foundation

// JS-17, JS-18, RUN-2e: what the rich result panel and the text prompt do, as values a test can drive
// without a window server. The windows in `NativePanelWindows.swift` draw these and forward clicks to
// them, and nothing else.

/// How the result is to be read (JS-17).
public enum PanelTextFormat: String, Sendable, Equatable {
    case text, markdown
}

/// What the result panel asks of whoever opened it: the app, over a `RichResultSession`.
public struct ResultPanelActions: Sendable {
    /// What Replace or Insert did, with the words for it when it did not.
    public enum Written: Sendable, Equatable {
        case written
        /// The destination did not verify. The explanation says why (RUN-2e).
        case refused(String)
        /// The action is over; the panel closes.
        case ended
        case failed
    }

    /// Whether Replace and Insert can be offered now. Nil explanation means they can.
    public enum Destination: Sendable, Equatable {
        case available
        case unavailable(String)
        case ended
    }

    public var destination: @Sendable () async -> Destination
    public var copy: @Sendable () async -> Bool
    public var replace: @Sendable () async -> Written
    public var insert: @Sendable () async -> Written
    public var close: @Sendable () async -> Void

    public init(
        destination: @escaping @Sendable () async -> Destination,
        copy: @escaping @Sendable () async -> Bool,
        replace: @escaping @Sendable () async -> Written,
        insert: @escaping @Sendable () async -> Written,
        close: @escaping @Sendable () async -> Void
    ) {
        self.destination = destination
        self.copy = copy
        self.replace = replace
        self.insert = insert
        self.close = close
    }
}

/// The rich result panel (JS-17, BAR-17, DIF-1a's functional half).
///
/// **Copy is always there.** Whatever the destination says, the result can be copied (RUN-2c).
/// **Replace and Insert are there only while the destination verifies**, and each one verifies it again
/// when clicked (RUN-2e): the check when the panel opens only decides whether the buttons start
/// enabled. A click that finds the destination gone disables both, with the reason under them. A write
/// that lands closes the panel, because the selection it was verified against is gone.
///
/// **Closing ends the invocation.** The close button, Escape, and the invocation ending under the panel
/// (a cancel, pause or revocation) each close it once.
@MainActor
public final class ResultPanelModel {
    public enum Writing: Equatable, Sendable {
        /// Not yet known; the buttons wait.
        case checking
        case available
        case unavailable(String)
    }

    public let title: String
    public let text: String
    public let format: PanelTextFormat
    public private(set) var writing: Writing = .checking
    /// The last thing a button did, for the status line and VoiceOver. Nil until something happened.
    public private(set) var status: String?
    public private(set) var isClosed = false
    /// A click is being answered; the buttons wait for it.
    public private(set) var isBusy = false

    /// Called after every change, to redraw.
    public var onChange: (() -> Void)?
    /// Called once, when the panel should go away.
    public var onClose: (() -> Void)?

    private let actions: ResultPanelActions

    public init(title: String, text: String, format: PanelTextFormat, actions: ResultPanelActions) {
        self.title = title
        self.text = text
        self.format = format
        self.actions = actions
    }

    public var canCopy: Bool { !isClosed && !isBusy }
    public var canWrite: Bool { !isClosed && !isBusy && writing == .available }

    /// The reason Replace and Insert are disabled, for under the buttons and their accessibility help.
    public var explanation: String? {
        switch writing {
        case .checking: PanelStrings.checking
        case .available: nil
        case .unavailable(let why): PanelStrings.unavailable(why)
        }
    }

    /// When the panel appears, and again whenever it is worth asking: whether the buttons start enabled.
    public func refresh() async {
        guard !isClosed else { return }
        let destination = await actions.destination()
        guard !isClosed else { return }
        switch destination {
        case .available: writing = .available
        case .unavailable(let why): writing = .unavailable(why)
        case .ended: return end()
        }
        onChange?()
    }

    public func copy() async {
        guard canCopy else { return }
        isBusy = true
        onChange?()
        let copied = await actions.copy()
        isBusy = false
        status = copied ? PanelStrings.copied : PanelStrings.copyFailed
        onChange?()
    }

    public func replace() async {
        await write(actions.replace)
    }

    public func insert() async {
        await write(actions.insert)
    }

    private func write(_ action: @Sendable () async -> ResultPanelActions.Written) async {
        guard canWrite else { return }
        isBusy = true
        onChange?()
        let written = await action()
        isBusy = false
        switch written {
        case .written:
            status = PanelStrings.written
            await close()
        case .refused(let why):
            writing = .unavailable(why)
            onChange?()
        case .ended:
            end()
        case .failed:
            status = PanelStrings.writeFailed
            onChange?()
        }
    }

    /// The close button or Escape.
    public func close() async {
        guard !isClosed else { return }
        end()
        await actions.close()
    }

    /// The invocation ended under the panel. Nothing more is asked of it.
    public func ended() {
        end()
    }

    private func end() {
        guard !isClosed else { return }
        isClosed = true
        onChange?()
        let close = onClose
        onClose = nil
        close?()
    }
}

/// How the prompt ended, as the panel knows it.
public enum PromptPanelAnswer: Sendable, Equatable {
    case submitted(String)
    case cancelled
}

/// The text prompt (JS-18): one labelled field, Submit and Cancel.
///
/// **Answered once.** Submit answers with the field as it is, empty included. Cancel, Escape and
/// closing the panel answer `cancelled`, which cancels the whole invocation (RUN-3). The invocation
/// ending first closes the panel without an answer of its own.
@MainActor
public final class PromptPanelModel {
    public let label: String
    public let placeholder: String
    /// The extension that asked, shown under the field so a prompt is never anonymous.
    public let source: String
    public var value: String
    public private(set) var answer: PromptPanelAnswer?

    /// Called once, when the panel should go away.
    public var onClose: (() -> Void)?

    private let respond: (PromptPanelAnswer) -> Void

    public init(label: String, placeholder: String, defaultValue: String, source: String, respond: @escaping (PromptPanelAnswer) -> Void) {
        self.label = label
        self.placeholder = placeholder
        self.value = defaultValue
        self.source = source
        self.respond = respond
    }

    public var isAnswered: Bool { answer != nil }

    public func submit() {
        answer(.submitted(value))
    }

    /// Cancel, Escape, or the close button.
    public func cancel() {
        answer(.cancelled)
    }

    /// The invocation ended under the prompt: close it, and answer nothing more.
    public func ended() {
        guard answer == nil else { return }
        answer = .cancelled
        closeOnce()
    }

    private func answer(_ given: PromptPanelAnswer) {
        guard answer == nil else { return }
        answer = given
        respond(given)
        closeOnce()
    }

    private func closeOnce() {
        let close = onClose
        onClose = nil
        close?()
    }
}
