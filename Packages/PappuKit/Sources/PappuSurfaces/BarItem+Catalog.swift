import Foundation
import PappuCore

extension BarIcon {
    /// What §8.11's specifier draws, as far as this build reads them.
    ///
    /// Nil when there is nothing to draw — no icon key anywhere up the inheritance chain, an explicit
    /// `icon: null`, a form this build does not render (Iconify, `svg:`, `data:`), or a file with no
    /// package to find it in. Every one of those has the same answer on the bar, and it is a good one:
    /// draw the name. A button with a blank square where its icon should be tells the user nothing; a
    /// button with a word on it tells them what it does.
    ///
    /// `directory` is the package's folder. A file icon is looked up inside it and nowhere else: a
    /// specifier of `../../secret.png` names a file the user never installed, so it is not drawn.
    public init?(_ icon: ActionIcon, directory: URL? = nil) {
        guard let specifier = icon.specifier else { return nil }
        let spec = IconSpec(parsing: specifier)
        switch spec.base {
        case .symbol(let name): self = .symbol(name)
        case .text(let text): self = .letters(text)
        case .file(let path):
            guard let file = Self.file(path, in: directory) else { return nil }
            self = .image(file, isTemplate: !spec.modifiers.preserveColor)
        case .unread: return nil
        }
    }

    /// `path` inside `directory`, or nil when it would name something outside it.
    public static func file(_ path: String, in directory: URL?) -> URL? {
        guard let directory, !path.hasPrefix("/") else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
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
            display = BarIcon(action.icon, directory: action.directory).map(Display.icon) ?? .text(name)
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

extension BarItemID {
    /// EXM-2's offer. Not an action's key: every `ActionKey` is written `identifier#action`, and this has
    /// no `#`, so no manifest can name a button that answers to it.
    public static let installExtension = BarItemID("pappuclip.install-extension")
}

extension BarItem {
    /// EXM-2: **Install Extension "Name"**, or the same words dimmed with the reason it cannot be.
    public init(_ offer: SnippetOffer) {
        switch offer {
        case .install(let name):
            let title = BarStrings.installExtension(name)
            self.init(id: .installExtension, name: title, display: .text(title))
        case .tooLong:
            self.init(unavailable: BarStrings.installTooLong)
        case .unreadable(let reason):
            self.init(unavailable: BarStrings.installUnreadable(reason))
        }
    }

    private init(unavailable explanation: String) {
        let title = BarStrings.installExtensionUnnamed
        self.init(
            id: .installExtension,
            name: title,
            display: .text(title),
            isEnabled: false,
            disabledExplanation: explanation
        )
    }
}
