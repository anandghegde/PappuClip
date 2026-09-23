import Foundation
import PappuCore

/// One thing the analyser found in the selection, and where it found it (FLT-2).
///
/// The four kinds are the four lists the public API already promises — `popclip.input.data.urls`,
/// `.nonHttpUrls`, `.emails`, `.paths` (JS-3) — and the four the matching pipeline's `requirements`
/// name (§8.5). Adding a fifth would mean a fifth list in an API this project does not own, so the
/// enumeration is closed on purpose.
public struct Detection: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// An `http` or `https` address, including a bare domain the analyser gave a scheme to.
        case url
        /// An address whose scheme is one of the bundled list's (`Resources/url-schemes.json`).
        case nonHTTPURL
        case email
        /// A path that exists on disk, with `~` and `..` already resolved.
        case path
    }

    public var kind: Kind
    /// Where it sits in the selection the analyser was given, so an action can narrow to it (§8.5 step 3).
    public var span: TextSpan
    /// What the detection means, normalised: a scheme added to a bare domain, `~` and `..` resolved in
    /// a path, the bare address for an email. `span.substring(of:)` is what the user actually wrote.
    public var value: String

    public init(kind: Kind, span: TextSpan, value: String) {
        self.kind = kind
        self.span = span
        self.value = value
    }
}
