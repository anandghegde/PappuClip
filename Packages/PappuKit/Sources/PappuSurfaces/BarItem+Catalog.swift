import Foundation
import PappuCore

extension BarIcon {
    /// What §8.11's specifier draws, as far as this build reads them.
    ///
    /// Nil when there is nothing to draw — no icon key anywhere up the inheritance chain, an explicit
    /// `icon: null`, or a form M1 does not render (a file in the package, Iconify, `svg:`, `data:`).
    /// Every one of those has the same answer on the bar, and it is a good one: draw the name. A
    /// button with a blank square where its icon should be tells the user nothing; a button with a
    /// word on it tells them what it does.
    public init?(_ icon: ActionIcon) {
        guard let specifier = icon.specifier else { return nil }
        switch IconSpec(parsing: specifier) {
        case .symbol(let name): self = .symbol(name)
        case .text(let text): self = .letters(text)
        case .unread: return nil
        }
    }
}

extension BarItem {
    /// One resolved action as a button (BAR-6).
    ///
    /// The title is resolved for `locale` here and nowhere else: `LocalizedText` keeps every language
    /// the author wrote, and the bar is the last moment at which the machine's language is the right
    /// question to ask. A test passes the locale it means and gets the same answer on every machine.
    public init(_ action: CatalogAction, locale: Locale = .current) {
        let name = action.title.text(for: locale)
        let display: Display
        switch action.showAs {
        case .text:
            display = .text(name)
        case .icon:
            display = BarIcon(action.icon).map(Display.icon) ?? .text(name)
        }
        self.init(
            id: BarItemID(action.key),
            name: name,
            display: display,
            wantsPrimaryDisplay: action.manifest.wantsPrimaryDisplay
        )
    }
}

extension BarItemID {
    /// A button's identity is its action's, spelled the one way `ActionKey` spells it, so that a click
    /// coming back from the bar names something the catalog can find again.
    public init(_ key: ActionKey) {
        self.init(key.description)
    }
}

extension BarContent {
    /// The bar for a resolution, in the user's action order (ALM-1, ALM-3).
    ///
    /// Uncapped, like the catalog. What fits is `BarLayout`'s question and the overflow is BAR-5a's;
    /// neither is answered by quietly dropping buttons here.
    public init(actions: [CatalogAction], locale: Locale = .current) {
        self.init(items: actions.map { BarItem($0, locale: locale) })
    }
}
