import Foundation
import PappuAX

/// Finds Cut, Copy and Paste in an app's menu bar and thereafter reads only whether they are enabled
/// (FLT-3, architecture §6.2).
///
/// Two rules shape all of it.
///
/// **Matched by key equivalent, never by title.** "Cut" is "Ausschneiden" in German and "切り取り" in
/// Japanese, and an app is free to call it anything at all; what it is not free to change is that the
/// item is Command-X. So the walk looks at `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers` and never
/// at `AXTitle`, which also means it reads nothing a user wrote.
///
/// **Located once per process.** Walking a menu bar is tens of Accessibility calls into another app,
/// and the attempt has 70 ms for the whole read (PRD §11.1). The three elements are cached against the
/// pid and reused; afterwards a context costs three `AXEnabled` reads. A cached element that has gone
/// stale — the app rebuilt its menus — is re-located once, and once only, so a pathological app costs
/// one extra walk rather than one per attempt.
@AXActor
public final class EditMenuProbe {
    /// How deep below the menu bar the items are looked for. A menu bar item's menu's items are three
    /// levels down; the fourth is for the apps that put an extra group in between.
    public nonisolated static let maxDepth = 4
    /// A ceiling on the whole walk. Large enough for a real app's menu bar — a big one is a few hundred
    /// items — and small enough that a malformed tree cannot take the read stage with it.
    public nonisolated static let maxNodes = 512

    /// `AXMenuItemCmdModifiers` is a mask of the modifiers *besides* Command, plus a bit meaning
    /// Command is not held at all. Zero is therefore Command alone, which is what all three of these
    /// items are on every Mac.
    public nonisolated static let commandAlone = 0

    private let world: any AXWorld
    private var cache: [pid_t: Items] = [:]

    public init(world: any AXWorld = SystemAXWorld()) {
        self.world = world
    }

    /// The three elements, once found. Any of them may be missing: an app without a Paste item is
    /// unusual but not broken.
    private struct Items {
        var cut: AXElement?
        var copy: AXElement?
        var paste: AXElement?

        var isEmpty: Bool { cut == nil && copy == nil && paste == nil }
        var isComplete: Bool { cut != nil && copy != nil && paste != nil }
    }

    /// - Parameters:
    ///   - application: The element for `pid`, with its messaging timeout already set by the caller —
    ///     this probe makes no timeout decisions of its own.
    public func availability(for pid: pid_t, in application: AXElement) -> EditMenuAvailability {
        var located = cache[pid]
        var fault: AXFault?
        if located == nil {
            let found = locate(in: application)
            fault = found.fault
            located = found.items
            cache[pid] = found.items
        }
        guard let items = located, !items.isEmpty else {
            return EditMenuAvailability(located: false, fault: fault)
        }

        var availability = read(items)
        // The app rebuilt its menus and the cached elements are gone. One more walk, then whatever it
        // says — a second failure is the app's answer and not a reason to keep trying.
        if availability.fault == .staleElement {
            cache[pid] = nil
            let found = locate(in: application)
            cache[pid] = found.items
            guard !found.items.isEmpty else {
                return EditMenuAvailability(located: false, fault: found.fault ?? .staleElement)
            }
            availability = read(found.items)
        }
        if availability.fault == nil { availability.fault = fault }
        return availability
    }

    /// Forgets a process's menu items, for a process that has quit or whose menus we want re-found.
    public func forget(_ pid: pid_t) {
        cache[pid] = nil
    }

    public func forgetAll() {
        cache.removeAll()
    }

    // MARK: Reading

    private func read(_ items: Items) -> EditMenuAvailability {
        var availability = EditMenuAvailability(located: true)
        func enabled(_ element: AXElement?) -> Bool? {
            guard let element else { return nil }
            switch world.attribute(.enabled, of: element) {
            case .success(let value):
                return value.asFlag
            case .failure(let fault):
                // The first fault is the one reported; a stale element makes all three fail the same
                // way and the caller only needs to be told once.
                if availability.fault == nil { availability.fault = fault }
                return nil
            }
        }
        availability.cut = enabled(items.cut)
        availability.copy = enabled(items.copy)
        availability.paste = enabled(items.paste)
        return availability
    }

    // MARK: Walking

    /// Breadth-first from the menu bar, because the items are shallow and the tree below them is not:
    /// depth-first would walk the whole of the first menu before reaching the second.
    private func locate(in application: AXElement) -> (items: Items, fault: AXFault?) {
        var items = Items()
        var fault: AXFault?

        let menuBar: AXElement
        switch world.attribute(.menuBar, of: application) {
        case .success(let value):
            guard let element = value.asFirstElement else { return (items, .unsupported) }
            menuBar = element
        case .failure(let failure):
            return (items, failure)
        }

        var frontier = [menuBar]
        var depth = 0
        var visited = 0

        while !frontier.isEmpty, depth < Self.maxDepth, visited < Self.maxNodes, !items.isComplete {
            var next: [AXElement] = []
            for element in frontier {
                guard visited < Self.maxNodes else { break }
                visited += 1
                claim(element, into: &items)
                if items.isComplete { break }
                switch world.attribute(.children, of: element) {
                case .success(let value):
                    next.append(contentsOf: value.asElements ?? [])
                case .failure(let failure):
                    // A menu with no children is the common case, not a fault worth reporting; only
                    // something that stops the walk is.
                    if failure != .unsupported, fault == nil { fault = failure }
                }
            }
            frontier = next
            depth += 1
        }

        return (items, fault)
    }

    /// Takes the element as Cut, Copy or Paste if its key equivalent says so, and leaves it alone
    /// otherwise. Never reads the title.
    private func claim(_ element: AXElement, into items: inout Items) {
        guard case .success(let value) = world.attribute(.menuItemCmdChar, of: element),
              let character = value.asString?.lowercased(),
              character.count == 1
        else { return }
        // Modifiers are read only for an item that already has the right character, so the ordinary
        // menu item costs one call and not two.
        guard case .success(let modifiers) = world.attribute(.menuItemCmdModifiers, of: element),
              modifiers.asNumber == Self.commandAlone
        else { return }

        switch character {
        case "x": if items.cut == nil { items.cut = element }
        case "c": if items.copy == nil { items.copy = element }
        case "v": if items.paste == nil { items.paste = element }
        default: break
        }
    }
}
