import Foundation

/// What a built-in action does, natively (PRD §7.4, architecture §19 item 2).
///
/// **Why this enumeration exists at all.** Principle 5 of the PRD says built-ins are extensions, and
/// they are: each one ships as a manifest in `Resources/BuiltinExtensions/`, and each can be disabled,
/// renamed, re-iconed, moved, duplicated and restored like any other. But the five P0 ones ship in M1
/// and the public API that could express them — JavaScript — arrives in M3. The decision recorded in
/// architecture §19 item 2 is to give them a **reserved executor** rather than to special-case them
/// above the extension model: they are ordinary manifests whose `executor` names something only the
/// app bundle is allowed to name. M3 and M4 move each one to the public API where the API can say it,
/// and any that cannot stay here and are documented.
///
/// The list is closed and short on purpose. Every case is a native implementation somebody has to
/// write and keep, so a case that is easy to add is the wrong shape. The three P1 built-ins —
/// Dictionary, Reveal in Finder and Spelling — are not here because they are M4; they join this list
/// when they are written, not before.
public enum BuiltinAction: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Cut the selection (PRD §7.4). ⇧ cuts as plain text.
    case cut
    /// Copy the selection. ⇧ copies as plain text.
    case copy
    /// Paste over the selection. ⇧ pastes as plain text.
    case paste
    /// Search for the selection with the chosen engine. ⇧ opens a background tab, ⌥ quotes the term.
    case search
    /// Open the addresses in the selection. ⇧ opens background tabs, ⌥ copies them as a list.
    case openLink = "open-link"
}

/// How an action runs (§8.4, architecture §9.5).
///
/// M1 has one case. The six non-JavaScript types — URL, Key Press, Service, Shortcut, AppleScript and
/// Shell Script — arrive in M2 and JavaScript in M3, each with its own keys and its own capability
/// analysis. They are not stubbed here: an enumeration case with no executor behind it is a promise
/// the code does not keep, and a manifest naming one is better refused at load with a message than
/// shown on a bar as a button that does nothing.
public enum ActionExecutor: Sendable, Equatable, Hashable {
    /// Reserved. Only a manifest from the app's own bundle may name it (`ManifestOrigin.appBundle`).
    case builtin(BuiltinAction)
}

/// Where a manifest came from, which is the whole of what makes the reserved executor safe.
///
/// This is not the extension-identity model — that is `Provenance` in M2 (SEC-8), with digests and
/// publisher records. It is the one distinction the reserved executor turns on, and it is separate
/// so that the check cannot be written as "the identifier starts with ours": an identifier is a
/// string in a file somebody else can also write.
public enum ManifestOrigin: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Shipped inside the application, and therefore covered by the app's own signature.
    case appBundle
    /// Everything else: installed from a file, a snippet, the registry or a development folder.
    case installed
}

extension ActionExecutor: Codable {
    /// `{"builtin": "copy"}`. A dictionary rather than a bare string, because M2's executors carry
    /// their own keys — `url`, `keyCombo`, `shellScript` — and a bare string would have to change
    /// shape when the first of them lands.
    private enum CodingKeys: String, CodingKey {
        case builtin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let builtin = try container.decodeIfPresent(BuiltinAction.self, forKey: .builtin) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "No executor this build can run. M1 runs `builtin` only; the other types are M2 and M3."
                )
            )
        }
        self = .builtin(builtin)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let action): try container.encode(action, forKey: .builtin)
        }
    }
}
