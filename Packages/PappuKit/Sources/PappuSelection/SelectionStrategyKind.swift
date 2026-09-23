import PappuCore

/// The five ways a selection can be read (ACT-9, architecture §4.5), in the order the chain tries them.
///
/// This is the *name* of a strategy, not a strategy: the objects that do the reading conform to
/// `SelectionStrategy` and arrive with the AX actor. A policy file, a `DIA-2` trace and a stack trace
/// all spell a strategy the same because the raw value is the case name.
public enum SelectionStrategyKind: String, Sendable, Codable, CaseIterable, Comparable {
    /// 1. `AXSelectedText` and friends on the focused element.
    case ax
    /// 2. WebKit text markers, for Safari, Mail and WKWebView hosts.
    case webkitMarkers
    /// 3. Enable the AX tree for a Chromium or Electron app, then read as for strategy 1. Needs a
    ///    `DetectionPolicy.axEnable` kind to set; without one there is nothing to enable and the
    ///    chain drops it.
    case axEnable
    /// 4. Browser-specific AppleScript. Needs Automation consent.
    case appleScript
    /// 5. Synthetic ⌘C through the `ClipboardBroker`. Never in a policy's declared order: whether it
    ///    runs is a matter of route and is answered by `DetectionPolicy.chain(for:)`.
    case syntheticCopy

    /// Its number in ACT-9, which is how the PRD, the spikes and the reports refer to it.
    public var number: Int {
        switch self {
        case .ax: 1
        case .webkitMarkers: 2
        case .axEnable: 3
        case .appleScript: 4
        case .syntheticCopy: 5
        }
    }

    /// Strategies 1–3 are measured against the 150 ms target, 4 and 5 against 350 ms (PRD §3.3).
    public var path: DetectionPath {
        self <= .axEnable ? .accessibility : .clipboardFallback
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }
}

/// Which attribute turns an app's Accessibility tree on for strategy 3 (architecture §4.5).
///
/// Which one an app wants, and whether enabling it is safe to hold or must be done per read, is M0
/// spike 4's output. The kind is per app because setting the wrong one is a side effect on a process
/// that did not ask for it.
public enum AXTreeEnabling: String, Sendable, Codable, CaseIterable {
    /// `AXManualAccessibility`, the Electron spelling.
    case manualAccessibility
    /// `AXEnhancedUserInterface`, the Chromium spelling.
    case enhancedUserInterface
    /// Both, for apps that answer to neither alone.
    case both
}
