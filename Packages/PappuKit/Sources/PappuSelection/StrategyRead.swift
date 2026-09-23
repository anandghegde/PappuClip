import CoreGraphics
import PappuAX
import PappuCore

/// What one strategy came back with, before the chain decides what the attempt as a whole read
/// (architecture §4.5).
///
/// It is not `SelectionRead`, and the difference is the whole reason both exist: a strategy reports what
/// *it* found, and only `SelectionStrategyChain` knows whether anything after it is still to be tried.
/// "This app has no Accessibility tree" is `unavailable` here and becomes `refused` only when every
/// strategy in the chain has said the same.
public struct StrategyRead: Sendable, Equatable {
    public enum Finding: String, Sendable, Codable, CaseIterable {
        /// Text came back.
        case text
        /// A place a caret sits, with nothing selected (ACT-3).
        case caret
        /// The strategy ran against a real element and found no selection.
        case nothing
        /// The strategy could not run at all: no focused element, no grant, no answer.
        case unavailable
    }

    public var finding: Finding
    /// The selection. Nil for every finding but `.text`.
    public var text: String?
    /// Where the selection is. Kept on `.nothing` as well as on `.text`, and deliberately: an app that
    /// says a selection is forty characters long and will not hand over the characters is the one case
    /// `ClipboardBroker.expectedCharacters` exists for (ACT-10e).
    public var range: AXTextRange?
    /// Where to draw the bar (BAR-3), in screen coordinates with a top-left origin.
    public var bounds: CGRect?
    /// The first thing that went wrong, for the inspector (DIA-2). A finding of `.nothing` with a fault
    /// beside it is ordinary: most elements answer `.unsupported` to most attributes.
    public var fault: AXFault?

    public init(
        finding: Finding,
        text: String? = nil,
        range: AXTextRange? = nil,
        bounds: CGRect? = nil,
        fault: AXFault? = nil
    ) {
        self.finding = finding
        self.text = text
        self.range = range
        self.bounds = bounds
        self.fault = fault
    }

    public static let nothing = StrategyRead(finding: .nothing)
}

extension AXTreeEnabling {
    /// The attributes this kind writes, in the order they are written. `both` is for the apps that
    /// answer to neither alone, and writing two attributes to one process is the one place the order
    /// could matter — Electron's spelling first, because an Electron app is also a Chromium one.
    public var switches: [AXTreeSwitch] {
        switch self {
        case .manualAccessibility: [.manualAccessibility]
        case .enhancedUserInterface: [.enhancedUserInterface]
        case .both: [.manualAccessibility, .enhancedUserInterface]
        }
    }
}

extension BudgetTable {
    /// A stage budget as the Accessibility API wants it: seconds, as a `Float`, never zero.
    ///
    /// AX reads zero as "use the global default", which is long enough to hand a wedged app the AX queue
    /// for seconds. The floor keeps every call bounded; the ceiling is the hard cutoff, past which no bar
    /// appears anyway (ACT-16).
    func messagingTimeout(
        _ timeout: Duration? = nil,
        for stage: BudgetStage = .read,
        on path: DetectionPath = .accessibility
    ) -> Float {
        let clamped = min(max(timeout ?? budget(for: stage, on: path), .milliseconds(1)), hardCutoff)
        // Through `Double` first: a `Float` division of attoseconds lands a hair either side of the
        // budget it was meant to be.
        return Float(Double(clamped.components.seconds) + Double(clamped.components.attoseconds) / 1e18)
    }
}
