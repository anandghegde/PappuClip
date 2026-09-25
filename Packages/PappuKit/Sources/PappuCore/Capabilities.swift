import Foundation

/// A capability the single install confirmation approves by naming it (safety spec §S4, EXM-5c).
///
/// Each case is one row of §S4's table, carrying what the sentence needs — a host, a Shortcut's name,
/// the keys — and nothing about how the sentence reads, which is `ConsentPresenter`'s and localised.
public enum ListedCapability: Sendable, Equatable, Hashable, Codable {
    /// A URL action whose host is fixed in the config: "Sends the selected text to example.com when
    /// you click it", or "Opens example.com" when the URL carries no text.
    case opensWebPage(host: String, withText: Bool)
    /// A URL action whose host comes from an option: "Opens a URL you configure, containing the
    /// selected text".
    case opensConfiguredURL(withText: Bool)
    /// A URL whose scheme is another app's (`things:`, `dict:`): the destination is that app.
    case opensAppLink(scheme: String, withText: Bool)
    /// A Key Press action with fixed combinations, as the menus write them: "Presses ⌘A in the current
    /// app".
    case pressesKeys([String])
    /// A Service by its menu name. Delegated automation: the Service can do whatever it does.
    case runsService(String)
    /// A Shortcut by name: "…the shortcut can do whatever Shortcuts allows".
    case runsShortcut(String)
    /// Sandboxed JavaScript that reads, returns, copies and pastes (P1 in the analysis, M3).
    case readsAndReplacesText
    /// The `dynamic` entitlement.
    case runsOnEveryAppearance
    /// `network` bounded by `networkHosts` (SEC-6).
    case sendsData(toHosts: [String])
}

/// A capability that needs its own approval, defaulting to "Don't Allow" (EXM-5d).
///
/// The raw value is the grant's key in the store, so it is part of the database's format: a case is
/// never renamed, only added.
public enum GatedCapability: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    /// Shell Script and AppleScript actions, and the `script` entitlement: "Runs a script outside the
    /// sandbox, with your user permissions".
    case script
    /// `network` without `networkHosts`: "Can send the selected text to any server".
    case network
    /// Script-driven `pressKey`, `performService`, `share`: "Can type and press keys in the current
    /// app". Reached only by JavaScript. It is disclosed for every extension with JavaScript, and it is
    /// not needed to run one: `HostAPIDispatcher` checks it when a script asks for one of those three,
    /// and refuses the call without it (SEC-7b).
    case syntheticInput = "synthetic-input"
    /// JavaScript whose reachable host methods this build cannot bound (EXM-5f, SEC-7c). Until M3's scan
    /// every script is this, which is the broader disclosure SEC-7c asks for.
    case unboundedCode = "unbounded-code"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// An extension's effective capabilities (SEC-7, architecture §9.3): what it can do, worked out from
/// what its actions are rather than read from what its manifest claims (EXM-5b).
public struct CapabilitySet: Sendable, Equatable, Hashable, Codable {
    /// In the order the actions first reach them, without repeats.
    public var listed: [ListedCapability]
    /// In `GatedCapability`'s order, without repeats.
    public var gated: [GatedCapability]
    /// Applications an AppleScript names in a `tell` block: SEC-7a's known destinations, sorted. A
    /// compiled script cannot be read, and then this says nothing — the script gate already says the
    /// broader thing (SEC-7c).
    public var controlledApps: [String]

    public init(listed: [ListedCapability] = [], gated: [GatedCapability] = [], controlledApps: [String] = []) {
        self.listed = listed
        self.gated = gated
        self.controlledApps = controlledApps
    }

    public static let none = CapabilitySet()

    /// EXM-15b's "only listed": one confirmation approves the lot.
    public var isListedOnly: Bool { gated.isEmpty }
}

/// SEC-7a for non-JavaScript actions; SEC-7c's broader answer for JavaScript until M3 can scan it.
///
/// The analysis is for **disclosure**. It never grants anything: enforcement is the runtime checking
/// an action's `gates` against the extension's grants at the moment it runs, so an analysis that
/// missed something makes a sentence wrong, not a door open.
public enum CapabilityAnalyzer {
    /// Everything `manifest` can do. `file` reads a package file by its relative path, as UTF-8; an
    /// AppleScript kept in a file is read for its `tell` targets through it.
    public static func effective(
        _ manifest: ExtensionManifest,
        file: (String) -> String? = { _ in nil }
    ) -> CapabilitySet {
        var listed: [ListedCapability] = []
        var gated: Set<GatedCapability> = []
        var apps: Set<String> = []

        func list(_ capability: ListedCapability) {
            if !listed.contains(capability) { listed.append(capability) }
        }

        for action in manifest.actions {
            gated.formUnion(gates(of: action, in: manifest))
            switch action.executor {
            case .builtin:
                break
            case .url(let url):
                list(destination(of: url.template))
            case .keyPress(let press):
                let keys = press.steps.compactMap { step -> String? in
                    if case .wait = step { return nil }
                    if let combo = try? KeyCombo.parse(step) { return combo.symbols }
                    if case .combo(let text) = step { return text }
                    return nil
                }
                if !keys.isEmpty { list(.pressesKeys(keys)) }
            case .service(let service):
                list(.runsService(service.name))
            case .shortcut(let shortcut):
                list(.runsShortcut(shortcut.name))
            case .appleScript(let script):
                let source: String? = switch script.source {
                case .inline(let text): text
                case .file(let path): file(path)
                }
                if let source { apps.formUnion(tellTargets(in: source)) }
            case .shellScript:
                break
            case .javaScript:
                break
            }
        }

        // A module's actions exist only once the helper has described it (JS-12), which is after the
        // approval this analysis is shown for, so its code is judged before there is anything to judge
        // it by: unbounded, like any script this build cannot scan. Each described action is JavaScript
        // and needs the same gates, so describing it discloses nothing the approval did not cover.
        if manifest.module != nil, manifest.module != .detection(false) {
            gated.insert(.unboundedCode)
        }
        // SEC-7b: JavaScript can reach the host methods that press keys and hand the text to other apps,
        // and until week 4's scan can say whether it does, each such extension discloses them. The grant
        // is checked when a script calls one, not when it runs, so declining it leaves the rest working.
        if gated.contains(.unboundedCode) { gated.insert(.syntheticInput) }
        // Entitlements are disclosed whatever the actions are. A claim this build has no use for is
        // still one the user should see before it has a use (SEC-7c).
        if manifest.entitlements.contains(.dynamic) { list(.runsOnEveryAppearance) }
        if manifest.entitlements.contains(.network), !manifest.networkHosts.isEmpty {
            list(.sendsData(toHosts: manifest.networkHosts))
        }
        gated.formUnion(entitlementGates(of: manifest))

        return CapabilitySet(listed: listed, gated: gated.sorted(), controlledApps: apps.sorted())
    }

    /// The same, reading files from the package folder. A file outside it is not read.
    public static func effective(_ manifest: ExtensionManifest, directory: URL?) -> CapabilitySet {
        effective(manifest) { path in
            guard let directory, !path.hasPrefix("/") else { return nil }
            let root = directory.standardizedFileURL.path
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root + "/") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The gated capabilities `action` needs granted before it may run (SEC-7d: denied access cannot
    /// be obtained through another action type, because each type answers here for itself).
    public static func gates(of action: ActionManifest, in manifest: ExtensionManifest) -> Set<GatedCapability> {
        switch action.executor {
        case .appleScript, .shellScript:
            [.script]
        case .javaScript:
            Set([.unboundedCode]).union(entitlementGates(of: manifest))
        case .builtin, .url, .keyPress, .service, .shortcut:
            []
        }
    }

    private static func entitlementGates(of manifest: ExtensionManifest) -> Set<GatedCapability> {
        var gates: Set<GatedCapability> = []
        if manifest.entitlements.contains(.script) { gates.insert(.script) }
        if manifest.entitlements.contains(.network), manifest.networkHosts.isEmpty { gates.insert(.network) }
        return gates
    }

    // MARK: URLs

    /// Where a URL template sends the user, and whether the selection goes with them.
    ///
    /// The host is fixed when it can be read from the template with every placeholder standing in for
    /// something harmless. An option placeholder anywhere up to the end of the host — `https://{popclip
    /// option site}/…`, or a template that *is* an option — means the user configures it.
    public static func destination(of template: String) -> ListedCapability {
        let withText = ["{popclip text}", "{pappuclip text}", "***"].contains {
            template.range(of: $0, options: .caseInsensitive) != nil
        }
        let schemeEnd = template.range(of: ":")
        let scheme = schemeEnd.map { String(template[..<$0.lowerBound]) }
        guard let scheme, !scheme.isEmpty, !scheme.contains("{"),
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
            return .opensConfiguredURL(withText: withText)
        }
        let lowered = scheme.lowercased()
        guard lowered == "http" || lowered == "https" else {
            return .opensAppLink(scheme: lowered, withText: withText)
        }
        var rest = template[schemeEnd!.upperBound...]
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        let authority = rest.prefix { !"/?#".contains($0) }
        guard !authority.contains("{"),
              let host = URL(string: "\(lowered)://\(authority)")?.host(), !host.isEmpty else {
            return .opensConfiguredURL(withText: withText)
        }
        return .opensWebPage(host: host.lowercased(), withText: withText)
    }

    // MARK: AppleScript

    /// Applications named in `tell application "…"` (or `tell app`, or `tell application id "…"`).
    public static func tellTargets(in source: String) -> Set<String> {
        let range = NSRange(source.startIndex..., in: source)
        return Set(tellPattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    private static let tellPattern = try! NSRegularExpression(
        pattern: #"\btell\s+(?:application|app)\s+(?:id\s+)?"([^"]+)""#,
        options: [.caseInsensitive]
    )
}
