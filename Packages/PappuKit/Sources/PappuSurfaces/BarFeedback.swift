/// BAR-12a's states, as one thing with one view behind it.
public enum BarFeedbackState: Sendable, Equatable {
    /// The buttons, as they were.
    case idle
    /// An action is running. `cancellable` is RUN-3: a click or a key takes it back.
    case running(cancellable: Bool)
    /// The "Copied" confirmation, which is its own state because it says a word rather than a mark.
    case copied
    case succeeded
    case failed
}

/// What moves, if anything. Reduce Motion is the whole reason this is a value rather than a call to
/// `NSView.shake()` (BAR-14).
public enum BarMotion: String, Sendable, Codable, CaseIterable {
    case none
    case spinner
    case shake
}

extension BarFeedbackState {
    /// The spinner keeps turning under Reduce Motion. It is not decoration — it is the only thing
    /// saying that work is still going on — and the setting asks for motion that conveys nothing to
    /// stop, which is the shake.
    public func motion(under appearance: BarAppearance) -> BarMotion {
        switch self {
        case .idle, .copied, .succeeded: .none
        case .running: .spinner
        case .failed: appearance.motion == .still ? .none : .shake
        }
    }

    /// Whether a click or a key in this state means "stop" rather than "run something" (RUN-3).
    public var isCancellable: Bool {
        if case .running(let cancellable) = self { return cancellable }
        return false
    }

    /// BAR-14: every change of state is announced, because a state that is only a picture is a state a
    /// VoiceOver user does not get. Nil for `.idle`, which is the absence of a state rather than one.
    public var announcement: String? {
        switch self {
        case .idle: nil
        case .running: BarStrings.feedbackRunning
        case .copied: BarStrings.feedbackCopied
        case .succeeded: BarStrings.feedbackSucceeded
        case .failed: BarStrings.feedbackFailed
        }
    }
}

/// The bar's feedback, and the announcement that goes with each change of it.
///
/// Changing to the state it is already in announces nothing: an action that reports success twice
/// should not say so twice to somebody listening.
public struct BarFeedback: Sendable, Equatable {
    public private(set) var state: BarFeedbackState = .idle

    public init() {}

    /// The announcement to post, or nil if there is nothing new to say.
    @discardableResult
    public mutating func change(to next: BarFeedbackState) -> String? {
        guard next != state else { return nil }
        state = next
        return next.announcement
    }

    public mutating func reset() {
        state = .idle
    }
}
