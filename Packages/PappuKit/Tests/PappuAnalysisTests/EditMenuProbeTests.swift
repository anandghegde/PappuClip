import Foundation
import PappuAnalysis
import PappuAX
import PappuTestSupport
import Testing

private let pid: pid_t = 501

private typealias Node = FakeAXWorld.Node

/// A menu item with a key equivalent, titled in whatever language the test feels like — the point is
/// that the title is never what is matched on.
private func item(_ title: String, _ character: String?, modifiers: Int = EditMenuProbe.commandAlone, enabled: Bool? = true) -> Node {
    Node(role: "AXMenuItem", title: title, enabled: enabled, cmdChar: character, cmdModifiers: character == nil ? nil : modifiers)
}

private func menu(_ title: String, _ items: [Node]) -> Node {
    Node(role: "AXMenuBarItem", children: [Node(role: "AXMenu", children: items)], title: title)
}

/// An app with the usual File and Edit menus, and the usual extra items around the three that matter.
private func application(edit: [Node]? = nil) -> Node {
    let edit = edit ?? [
        item("Undo", "z"),
        item("Cut", "x"),
        item("Copy", "c"),
        item("Paste", "v"),
        item("Paste and Match Style", "v", modifiers: 1),
        item("Select All", "a"),
    ]
    return Node(
        role: "AXApplication",
        menuBar: Node(role: "AXMenuBar", children: [
            menu("File", [item("New", "n"), item("Open…", "o"), item("Close", "w")]),
            menu("Edit", edit),
        ])
    )
}

private func world(_ node: Node) -> FakeAXWorld {
    let world = FakeAXWorld()
    world.setApplication(node, in: pid)
    return world
}

private func probe(_ world: FakeAXWorld) async -> EditMenuProbe {
    await EditMenuProbe(world: world)
}

/// FLT-3's Cut, Copy and Paste: found by key equivalent, cached per process, and read afterwards one
/// attribute at a time (architecture §6.2).
@Suite struct EditMenuProbeTests {

    @Test func findsCutCopyAndPasteByTheirKeyEquivalents() async {
        let world = world(application())
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.located)
        #expect(availability.cut == true)
        #expect(availability.copy == true)
        #expect(availability.paste == true)
        #expect(availability.fault == nil)
    }

    /// The whole reason the probe matches on the key equivalent: a German or Japanese Mac has the same
    /// three items under different names.
    @Test func theTitlesLanguageDoesNotMatter() async {
        let world = world(application(edit: [
            item("Ausschneiden", "x"),
            item("Kopieren", "c"),
            item("Einsetzen", "v"),
        ]))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.cut == true)
        #expect(availability.copy == true)
        #expect(availability.paste == true)
    }

    /// And the probe proves it by never asking: a menu item's title is text somebody wrote, and the
    /// probe has no business reading it.
    @Test func aMenuItemsTitleIsNeverRead() async {
        let world = world(application())
        _ = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(!world.asked.contains(.title))
    }

    /// Shift-Command-V is Paste and Match Style, which is a different item with a different meaning.
    @Test func anItemWithAnExtraModifierIsNotTheOne() async {
        let world = world(application(edit: [
            item("Paste and Match Style", "v", modifiers: 1),
            item("Paste", "v"),
        ]))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.paste == true)
        // The real Paste is the one whose enabled state was read, not the first `v` in the menu.
        #expect(availability.cut == nil)
        #expect(availability.copy == nil)
    }

    @Test func anItemThatIsDisabledIsReportedAsDisabled() async {
        let world = world(application(edit: [
            item("Cut", "x", enabled: false),
            item("Copy", "c", enabled: true),
            item("Paste", "v", enabled: false),
        ]))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.cut == false)
        #expect(availability.copy == true)
        #expect(availability.paste == false)
    }

    /// Nil is "the menu has no opinion", which is not the same as "no". `ContextProbe` is what turns
    /// that into an answer.
    @Test func anItemThatWillNotSayWhetherItIsEnabledIsNotAnAnswer() async {
        let world = world(application(edit: [
            item("Cut", "x", enabled: nil),
            item("Copy", "c", enabled: nil),
            item("Paste", "v", enabled: nil),
        ]))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.located)
        #expect(availability.cut == nil)
        #expect(availability.copy == nil)
        #expect(availability.paste == nil)
    }

    @Test func anAppWithNoMenuBarSaysSoRatherThanFailing() async {
        let world = world(Node(role: "AXApplication"))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(!availability.located)
        #expect(availability.cut == nil)
        #expect(availability.fault == .unsupported)
    }

    @Test func anAppWithNoEditMenuSaysSoRatherThanFailing() async {
        let world = world(Node(
            role: "AXApplication",
            menuBar: Node(role: "AXMenuBar", children: [menu("File", [item("New", "n")])])
        ))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(!availability.located)
    }

    // MARK: The cache

    /// The reason the cache exists: a walk is tens of calls into another app and the read stage has
    /// 70 ms for everything.
    @Test func theItemsAreFoundOnceAndOnlyTheirEnabledStateIsReadAfterwards() async {
        let world = world(application())
        let probe = await probe(world)
        _ = await probe.availability(for: pid, in: world.application(pid: pid))
        let afterFirst = world.asked.count
        let walked = world.asked.filter { $0 == .menuItemCmdChar }.count
        #expect(walked > 0)

        _ = await probe.availability(for: pid, in: world.application(pid: pid))

        #expect(world.asked.filter { $0 == .menuItemCmdChar }.count == walked, "the menu bar was walked twice")
        #expect(world.asked.count - afterFirst == 3, "a cached context costs one AXEnabled read per item")
        #expect(world.asked.suffix(3) == [.enabled, .enabled, .enabled])
    }

    @Test func forgettingAProcessMakesTheNextContextWalkAgain() async {
        let world = world(application())
        let probe = await probe(world)
        _ = await probe.availability(for: pid, in: world.application(pid: pid))
        let walked = world.asked.filter { $0 == .menuItemCmdChar }.count

        await probe.forget(pid)
        _ = await probe.availability(for: pid, in: world.application(pid: pid))

        #expect(world.asked.filter { $0 == .menuItemCmdChar }.count == walked * 2)
    }

    /// The app rebuilt its menus and the cached elements are gone. One more walk finds the new ones.
    @Test func aStaleElementIsRelocatedOnce() async {
        let stale = application()
        let world = world(stale)
        let probe = await probe(world)
        _ = await probe.availability(for: pid, in: world.application(pid: pid))

        for menuBarItem in stale.menuBar?.children ?? [] {
            for menu in menuBarItem.children ?? [] {
                for item in menu.children ?? [] { item.fail(.enabled, with: .staleElement) }
            }
        }
        world.setApplication(application(), in: pid)
        let availability = await probe.availability(for: pid, in: world.application(pid: pid))

        #expect(availability.located)
        #expect(availability.cut == true)
        #expect(availability.paste == true)
        #expect(availability.fault == nil)
    }

    /// And only once: an app whose menus are stale every time costs one extra walk, not one per read.
    @Test func anAppThatIsStaleTwiceIsNotWalkedForever() async {
        let stale = application()
        for menuBarItem in stale.menuBar?.children ?? [] {
            for menu in menuBarItem.children ?? [] {
                for item in menu.children ?? [] { item.fail(.enabled, with: .staleElement) }
            }
        }
        let world = world(stale)
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(availability.fault == .staleElement)
        #expect(world.asked.filter { $0 == .menuItemCmdChar }.count > 0)
        #expect(availability.cut == nil)
    }

    /// Two processes are two menu bars. A cache keyed on anything less would answer for the wrong app.
    @Test func eachProcessGetsItsOwnItems() async {
        let world = FakeAXWorld()
        world.setApplication(application(), in: pid)
        world.setApplication(application(edit: [item("Copy", "c", enabled: false)]), in: 909)
        let probe = await probe(world)

        let first = await probe.availability(for: pid, in: world.application(pid: pid))
        let second = await probe.availability(for: 909, in: world.application(pid: 909))

        #expect(first.copy == true)
        #expect(second.copy == false)
        #expect(second.cut == nil)
    }

    /// A tree that never ends is a malformed app, not a reason to hand it the read stage.
    @Test func aMenuBarThatGoesOnForeverIsBounded() async {
        let deep = Node(role: "AXMenuBar", children: (0..<64).map { index in
            menu("Menu \(index)", (0..<64).map { item("Item \($0)", nil) })
        })
        let world = world(Node(role: "AXApplication", menuBar: deep))
        let availability = await probe(world).availability(for: pid, in: world.application(pid: pid))

        #expect(!availability.located)
        #expect(world.asked.count < 4 * EditMenuProbe.maxNodes)
    }
}
