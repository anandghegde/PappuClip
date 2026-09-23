import Foundation
import PappuSelection

/// One button's identity: an `ActionKey` as a string, which is what `BarItemID(_: ActionKey)` writes
/// and what a click coming back from the bar is looked up by. The raw value stays open rather than
/// being the key itself so that `PappuSurfaces` does not have to know the manifest model to draw a
/// button, and so a caller with no catalog — a test, the harness — can still make one.
public struct BarItemID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What a button draws (BAR-6). The full icon-specifier grammar — text, file, SF Symbol, Iconify,
/// `svg:`, `data:` and the modifiers — is §8.11, and lands with extensions in M2 and M4. These two
/// forms are what the five bundled built-ins need.
public enum BarIcon: Sendable, Equatable {
    /// An SF Symbol name, drawn as a template so the accent highlight can tint it.
    case symbol(String)
    /// Up to three characters drawn in the icon's place (§8.11).
    case letters(String)
}

/// One button on the bar.
///
/// `name` is the action's name and is used three times over: as the tooltip (BAR-6), as the
/// VoiceOver label (BAR-14), and as the button's face when `display` is `.text`. That is deliberate —
/// an icon-only button with no name would be unreachable by either route.
public struct BarItem: Sendable, Equatable, Identifiable {
    public enum Display: Sendable, Equatable {
        case icon(BarIcon)
        case text(String)
    }

    public var id: BarItemID
    public var name: String
    public var display: Display
    /// BAR-4: an action may ask to sit under the pointer. Copy and Paste use it. The placement that
    /// honours it is M4; the flag rides along from M1 so a manifest never loses it.
    public var wantsPrimaryDisplay: Bool
    public var isEnabled: Bool
    /// Why it cannot be run, in words. The tooltip and VoiceOver both say it, because a button that is
    /// dimmed and silent is the thing BAR-17 names as a failure (M4's Replace Selection is the case).
    public var disabledExplanation: String?

    public init(
        id: BarItemID,
        name: String,
        display: Display,
        wantsPrimaryDisplay: Bool = false,
        isEnabled: Bool = true,
        disabledExplanation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.display = display
        self.wantsPrimaryDisplay = wantsPrimaryDisplay
        self.isEnabled = isEnabled
        self.disabledExplanation = disabledExplanation
    }

    /// What the pointer hovering over this button should say (BAR-6), and what VoiceOver reads (BAR-14).
    public var tooltip: String {
        guard !isEnabled, let explanation = disabledExplanation else { return name }
        return BarStrings.disabledTooltip(name: name, explanation: explanation)
    }
}

/// What one appearance of the bar shows.
///
/// Paging is BAR-5a and belongs to M4; a `BarContent` is one page's worth, and `BarLayout` says how
/// much of it fits so that the page split has somewhere to start.
public struct BarContent: Sendable, Equatable {
    public var items: [BarItem]

    public init(items: [BarItem]) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
}

/// Where the bar's buttons come from. `ActionResolver` is M1 week 5 (FLT-1); this is the seam it
/// arrives through, so the bar can be built and tested before anything decides what it holds.
public protocol BarContentProviding: Sendable {
    func content(for presentation: AttemptPresentation) async -> BarContent
}

/// A button press, with the modifiers that were held when it happened (BAR-11).
///
/// The modifiers are carried rather than read again at invocation time on purpose: by the time the
/// action runs the user has let go, and ACT-19 forbids a keyboard tap that is not a surface's own.
/// They come from the click's own event, which is where the flags already are.
public struct BarClick: Sendable, Equatable {
    public var item: BarItemID
    public var modifiers: PointerEvent.Modifiers
    /// How the press was made, which the inspector wants and RUN-3 will want.
    public var source: Source

    public enum Source: String, Sendable, Codable, CaseIterable {
        case mouse
        /// Return in compact keyboard mode (BAR-9a).
        case keyboard
    }

    public init(item: BarItemID, modifiers: PointerEvent.Modifiers = [], source: Source = .mouse) {
        self.item = item
        self.modifiers = modifiers
        self.source = source
    }
}

/// What a press turns into. `InvocationManager` is M1 week 5 (RUN-1); this is the seam it arrives
/// through, and the reason the bar has no idea what an action is.
public protocol BarActionInvoking: Sendable {
    func invoke(_ click: BarClick, for presentation: AttemptPresentation) async
    func cancelRunningAction() async
}

extension BarActionInvoking {
    /// RUN-3: a press while an action is running takes it back rather than starting another. The
    /// cancellation itself is `InvocationManager`'s, in M1 week 5; this default is what the bar does
    /// against a resolver that has nothing to cancel.
    public func cancelRunningAction() async {}
}
