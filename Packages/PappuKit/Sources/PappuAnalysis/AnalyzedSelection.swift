import Foundation
import PappuCore

/// What the analyser made of one selection (FLT-2, architecture §6.1).
///
/// Immutable, and the only thing downstream of the read that holds the text: `ActionResolver` filters
/// against it (FLT-5), the bar draws from it, and the JavaScript host copies what an approved extension
/// is entitled to see out of it (JS-3). Nothing here is ever written to a trace or a diagnostic
/// payload — `AttemptTrace` carries counts and kinds, never `text` or `value` (DIA-4).
public struct AnalyzedSelection: Sendable, Equatable, Codable {
    /// The selection as it was read. The full text always stays available (§8.5 step 5), whatever an
    /// action narrows to.
    public let text: String
    /// In the order they appear in the text, and never overlapping: an address inside an email is the
    /// email, and a domain inside a path is the path.
    public let detections: [Detection]
    /// Whether a limit stopped the analyser before the end of the text or before every candidate was
    /// judged — a selection past `AnalysisLimits.maxCharacters`, more detections than the cap allows,
    /// or the file-existence budget running out. The bar behaves the same either way; this is here so
    /// that the inspector can say why a detection the user expected is missing (DIA-2), and so that
    /// ACT-13's large-selection bounds have somewhere to report from in M4.
    public let bounded: Bool

    public init(text: String, detections: [Detection] = [], bounded: Bool = false) {
        self.text = text
        self.detections = detections
        self.bounded = bounded
    }

    public func detections(_ kind: Detection.Kind) -> [Detection] {
        detections.filter { $0.kind == kind }
    }

    /// `popclip.input.data.urls` (JS-3) and the `urls` requirement (§8.5).
    public var urls: [String] { values(.url) }
    public var nonHTTPURLs: [String] { values(.nonHTTPURL) }
    public var emails: [String] { values(.email) }
    public var paths: [String] { values(.path) }

    private func values(_ kind: Detection.Kind) -> [String] {
        detections.compactMap { $0.kind == kind ? $0.value : nil }
    }

    /// `popclip.input.isUrl`, and the `isurl` requirement: the selection is one address and nothing
    /// else, whitespace either side apart.
    ///
    /// Any of the three address kinds counts. An extension that asks for `isurl` wants "the user
    /// selected a link", and a bare `omnifocus:///task/1` is as much a link as an `https://` one.
    public var isSingleURL: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, detections.count == 1, let only = detections.first else { return false }
        guard only.kind != .path else { return false }
        return only.span.substring(of: text)?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
    }

    /// The first address in the selection, which is what the `url` requirement narrows to (§8.5 step 3).
    public var firstURL: Detection? {
        detections.first { $0.kind == .url || $0.kind == .nonHTTPURL }
    }
}
