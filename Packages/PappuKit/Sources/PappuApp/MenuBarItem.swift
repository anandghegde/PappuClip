import AppKit
import Foundation

/// The status item, and nothing else (PRD §7.5).
///
/// Everything the menu *is* — which commands exist in which state, what the status line says, where the
/// dividing lines fall — is `MenuBarMenu`, decided as a value and tested without AppKit. This turns that
/// value into `NSMenuItem`s and turns a click back into a `MenuCommand`. It is the whole of the untested
/// surface, and it is kept this thin on purpose.
///
/// The menu is rebuilt in `menuNeedsUpdate`, every time it is about to open, because a pause expires on a
/// clock nobody is watching: an hour's pause that ran out while the app sat idle has to read as running
/// the moment the user looks (ACT-18). Building it costs a handful of strings.
///
/// Hiding the icon and dragging snippets onto it are P1 (PRD §7.5) and are not here.
@MainActor
public final class MenuBarItem: NSObject, NSMenuDelegate {
    /// Provisional. A paperclip is legible at menu-bar size and says "this app is about the thing you
    /// have your hands on"; the designed icon is M6's. It is drawn as a template so that macOS tints it
    /// for light, dark and the highlighted menu.
    static let symbolName = "paperclip"

    private let menu: @MainActor () -> MenuBarMenu
    private let perform: @MainActor (MenuCommand) -> Void
    private var item: NSStatusItem?

    public init(
        menu: @escaping @MainActor () -> MenuBarMenu,
        perform: @escaping @MainActor (MenuCommand) -> Void
    ) {
        self.menu = menu
        self.perform = perform
        super.init()
    }

    public func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: Self.symbolName,
            accessibilityDescription: AppStrings.menuBarLabel
        )
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel(AppStrings.menuBarLabel)
        let built = NSMenu()
        built.delegate = self
        item.menu = built
        self.item = item
    }

    public func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in self.menu().entries {
            menu.addItem(Self.item(for: entry, target: self))
        }
    }

    private static func item(for entry: MenuBarMenu.Entry, target: MenuBarItem) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .status(let text):
            // Not a command and not a thing to click. `NSMenuItem` with no action is drawn greyed, which
            // is what a status line should look like.
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .item(let model):
            let item = NSMenuItem(
                title: model.title,
                action: #selector(MenuBarItem.chose(_:)),
                keyEquivalent: model.keyEquivalent ?? ""
            )
            item.target = target
            item.representedObject = model.command.rawValue
            item.state = model.isOn ? .on : .off
            return item
        }
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = MenuCommand(rawValue: raw) else {
            return
        }
        perform(command)
    }
}
