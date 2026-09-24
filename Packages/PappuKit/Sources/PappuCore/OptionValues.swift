import Foundation

/// An extension instance's option values as its actions see them (§8.9).
///
/// One function, used by everything that reads options: the matcher's `option-<id>=<value>`
/// requirements (§8.5), `{popclip option <id>}` in a URL, `POPCLIP_OPTION_<ID>` in a script, and the
/// settings sheet's first draw. If each of those applied §8.9's defaults itself, an unset boolean
/// would be true in one place and empty in another, and a requirement would disagree with the sheet
/// the user can see.
public enum OptionValues {
    /// A boolean as a requirement and a script read it: PopClip's `1` and `0`.
    public static let on = "1"
    public static let off = "0"

    /// Every option's value, stored or defaulted.
    ///
    /// - `stored` holds what the user set, for this instance only (§8.9: values are per instance).
    /// - `secrets` holds the Keychain's values, fetched by the caller only when something is about to
    ///   run — they are never part of what the matcher sees, and a missing one is an empty string.
    /// - A `password` is never stored (it exists only to be handed to `auth`, M3), so it reads as empty.
    /// - A `heading` has no value and no key.
    public static func effective(
        _ options: [OptionManifest],
        stored: [String: String],
        secrets: [String: String] = [:]
    ) -> [String: String] {
        var values: [String: String] = [:]
        for option in options {
            guard let identifier = option.identifier else { continue }
            switch option.kind {
            case .heading:
                continue
            case .password:
                values[identifier] = ""
            case .secret:
                values[identifier] = secrets[identifier] ?? ""
            case .string, .boolean, .multiple:
                values[identifier] = stored[identifier].map { normalised($0, for: option) } ?? defaultValue(of: option)
            }
        }
        return values
    }

    /// §8.9's default: a string is empty, a boolean is on, a multiple is its first value, and a secret
    /// has none. An author's `defaultValue` wins over each of those.
    public static func defaultValue(of option: OptionManifest) -> String {
        switch (option.kind, option.defaultValue) {
        case (.boolean, .boolean(let value)?): return value ? on : off
        case (.boolean, .string(let text)?): return truthy(text) ? on : off
        case (.boolean, nil): return on
        case (.secret, _), (.password, _), (.heading, _): return ""
        case (_, .string(let text)?): return text
        case (_, .boolean(let value)?): return value ? "true" : "false"
        case (.multiple, nil): return option.values.first ?? ""
        case (.string, nil): return ""
        }
    }

    /// A stored boolean in the one spelling the rest of the app compares against. Anything else is
    /// kept as the user left it.
    private static func normalised(_ value: String, for option: OptionManifest) -> String {
        guard option.kind == .boolean else { return value }
        return truthy(value) ? on : off
    }

    private static func truthy(_ text: String) -> Bool {
        ["1", "true", "yes", "on"].contains(text.lowercased())
    }
}
