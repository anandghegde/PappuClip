import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.apple.Safari")

/// The read stage's budget on the Accessibility path (PRD §11.1), in seconds, as AX takes it.
private let readTimeout = Float(0.070)

private typealias Node = FakeAXWorld.Node

private struct TheGateRefused: Error {}

private func permit(for app: TargetApp = target) throws -> ReadPermit {
    let decision = PrivacyGate(PrivacyRules()).evaluate(route: .automatic, target: app, secureInput: .clear)
    guard let permit = decision.permit() else { throw TheGateRefused() }
    return permit
}

// MARK: Building an app

private func editItem(_ character: String, enabled: Bool) -> Node {
    Node(role: "AXMenuItem", enabled: enabled, cmdChar: character, cmdModifiers: EditMenuProbe.commandAlone)
}

/// A menu bar whose Cut, Copy and Paste say what the test wants them to say.
private func menuBar(cut: Bool = true, copy: Bool = true, paste: Bool = true) -> Node {
    Node(role: "AXMenuBar", children: [
        Node(role: "AXMenuBarItem", children: [Node(role: "AXMenu", children: [
            editItem("x", enabled: cut),
            editItem("c", enabled: copy),
            editItem("v", enabled: paste),
        ])]),
    ])
}

private func application(menu: Node? = nil, window: Node? = nil) -> Node {
    Node(role: "AXApplication", menuBar: menu, focusedWindow: window)
}

private func world(_ application: Node, focused: Node?) -> FakeAXWorld {
    let world = FakeAXWorld()
    world.setApplication(application, in: target.pid)
    world.setFocused(focused, in: target.pid)
    return world
}

private func contextProbe(_ world: FakeAXWorld) async -> ContextProbe {
    await ContextProbe(world: world, names: FakeAppNames([target.pid: "Safari"]))
}

/// FLT-3 and FLT-6: what the context records about the app the selection came from, and what the bar
/// is allowed to offer on the strength of it (architecture §6.2).
@Suite struct ContextProbeTests {

    // MARK: The app (FLT-3)

    @Test func namesTheAppAndItsBundle() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXTextArea"))
        let context = await contextProbe(world).probe(try permit())

        #expect(context.app.pid == target.pid)
        #expect(context.app.bundleID == "com.apple.Safari")
        #expect(context.app.name == "Safari")
        #expect(context.app.displayName == "Safari")
    }

    @Test func aProcessWithNoNameAndNoBundleIsStillAnApp() async throws {
        let nameless = TargetApp(pid: 777, bundleID: nil)
        let world = FakeAXWorld()
        world.setApplication(application(), in: nameless.pid)
        let probe = await ContextProbe(world: world, names: FakeAppNames())
        let context = await probe.probe(try permit(for: nameless))

        #expect(context.app.displayName == "process 777")
        #expect(context.role == nil)
    }

    // MARK: Editability (FLT-3)

    /// The app's own answer to the question, which is the only one that is not an inference.
    @Test func aFieldTheAppLetsUsWriteToIsEditable() async throws {
        let field = Node(role: "AXTextField")
        field.allowWriting(.selectedText)
        let world = world(application(menu: menuBar()), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.isEditable)
        #expect(context.editability.source == .settableSelectedText)
        #expect(world.settableChecks == [.selectedText])
    }

    @Test func aControlTheAppRefusesToWriteToIsReadOnly() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXStaticText"))
        let context = await contextProbe(world).probe(try permit())

        #expect(!context.isEditable)
        #expect(context.editability.source == .settableSelectedText)
    }

    /// FLT-6's web half: a comment box inside a page is editable even though the page is not, and
    /// `AXEditableAncestor` is how WebKit and Chromium say so.
    @Test func aTextBoxInsideAWebPageIsEditableByItsAncestor() async throws {
        let box = Node(role: "AXTextField")
        box.editableAncestor = Node(role: "AXTextField")
        let world = world(application(menu: menuBar()), focused: box)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.isEditable)
        #expect(context.editability.source == .editableAncestor)
    }

    /// When the app will not answer the settable question at all, the role is the cheap signal left.
    @Test func anAppThatWillNotSayFallsBackToTheRole() async throws {
        let field = Node(role: "AXTextField")
        field.failSettableChecks(with: .unsupported)
        let world = world(application(menu: menuBar()), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.isEditable)
        #expect(context.editability.source == .role)
    }

    @Test func anAppThatAnswersNothingAtAllIsTreatedAsReadOnly() async throws {
        let world = world(application(menu: menuBar()), focused: nil)
        let context = await contextProbe(world).probe(try permit())

        #expect(!context.isEditable)
        #expect(context.editability.source == .unanswered)
        #expect(context.fault == .unsupported)
    }

    // MARK: Cut, Copy and Paste (FLT-3, FLT-6)

    @Test func anEditableFieldOffersAllThree() async throws {
        let field = Node(role: "AXTextField")
        field.allowWriting(.selectedText)
        let world = world(application(menu: menuBar()), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.canCut)
        #expect(context.canCopy)
        #expect(context.canPaste)
    }

    /// FLT-6, on a native control.
    @Test func readOnlyTextNeverOffersCutOrPaste() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXStaticText"))
        let context = await contextProbe(world).probe(try permit())

        #expect(!context.canCut)
        #expect(!context.canPaste)
        #expect(context.canCopy, "a paragraph one cannot edit is still one that can be copied")
    }

    /// FLT-6 by name: "including read-only web content in Chromium browsers". Chromium leaves both
    /// items enabled over a page nobody can type into, so the menu is asked and then overruled.
    @Test func readOnlyWebContentInAChromiumBrowserOffersNeitherCutNorPaste() async throws {
        let page = Node(role: AXRole.webArea, title: "An article", url: URL(string: "https://example.com/article"))
        let world = world(application(menu: menuBar(cut: true, copy: true, paste: true)), focused: page)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.menu.cut == true, "Chromium said yes")
        #expect(context.menu.paste == true, "Chromium said yes")
        #expect(!context.canCut, "and FLT-6 says no")
        #expect(!context.canPaste, "and FLT-6 says no")
        #expect(context.canCopy)
        #expect(context.isWebContent)
    }

    /// The menu narrows what editability allows: an empty clipboard is the app's business, not ours.
    @Test func anEditableFieldWithAnEmptyClipboardOffersNoPaste() async throws {
        let field = Node(role: "AXTextField")
        field.allowWriting(.selectedText)
        let world = world(application(menu: menuBar(paste: false)), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.canCut)
        #expect(!context.canPaste)
    }

    /// An app with no menu bar has no opinion, and editability decides alone.
    @Test func anAppWithNoEditMenuFallsBackToEditability() async throws {
        let field = Node(role: "AXTextField")
        field.allowWriting(.selectedText)
        let world = world(application(), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(!context.menu.located)
        #expect(context.canCut)
        #expect(context.canCopy)
        #expect(context.canPaste)
    }

    // MARK: Formatting (FLT-3)

    @Test func aControlThatOffersAnAttributedStringHasFormatting() async throws {
        let field = Node(role: "AXTextArea")
        field.offer(.attributedStringForRange)
        let world = world(application(menu: menuBar()), focused: field)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.hasFormatting)
        #expect(world.parameterizedChecks == [.attributedStringForRange])
    }

    @Test func aPlainControlHasNoFormatting() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXTextField"))
        let context = await contextProbe(world).probe(try permit())

        #expect(!context.hasFormatting)
    }

    // MARK: The browser page (FLT-3)

    @Test func aBrowsersPageAddressAndTitleAreRead() async throws {
        let page = Node(role: AXRole.webArea, title: "An article", url: URL(string: "https://example.com/article"))
        let world = world(application(menu: menuBar(), window: Node(role: "AXWindow", title: "Window")), focused: page)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser?.url == URL(string: "https://example.com/article"))
        #expect(context.browser?.title == "An article")
        #expect(context.browser?.source == .accessibility)
    }

    /// A web area often has no title of its own; the window's is the page's.
    @Test func aPageWithNoTitleOfItsOwnBorrowsTheWindows() async throws {
        let page = Node(role: AXRole.webArea, url: URL(string: "https://example.com/article"))
        let world = world(application(menu: menuBar(), window: Node(role: "AXWindow", title: "An article")), focused: page)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser?.title == "An article")
    }

    /// The focus is a text box inside the page, so the page is found by walking the window down to it.
    @Test func aTextBoxInAPageFindsTheWebAreaInTheWindow() async throws {
        let page = Node(role: AXRole.webArea, title: "Comments", url: URL(string: "https://example.com/comments"))
        let window = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", children: [Node(role: "AXToolbar")]),
            Node(role: "AXGroup", children: [page]),
        ], title: "Comments")
        let box = Node(role: "AXTextField")
        box.editableAncestor = Node(role: "AXTextField")
        let world = world(application(menu: menuBar(), window: window), focused: box)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser?.url == URL(string: "https://example.com/comments"))
        #expect(context.isEditable)
        #expect(context.canPaste)
    }

    /// A native app has no web area, and finding that out must not cost a walk of its window on every
    /// selection on the Mac.
    @Test func aNativeAppsWindowIsNotWalkedLookingForAPage() async throws {
        let window = Node(role: "AXWindow", children: [Node(role: "AXGroup")], title: "Untitled")
        let world = world(application(menu: menuBar(), window: window), focused: Node(role: "AXTextArea"))
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser == nil)
        #expect(!context.isWebContent)
        #expect(!world.asked.contains(.focusedWindow))
        #expect(!world.asked.contains(.url))
    }

    @Test func aPageThatSaysNeitherAddressNorTitleIsNoPage() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: AXRole.webArea))
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser == nil)
    }

    /// A bounded walk, so a window full of chrome cannot take the read stage with it.
    @Test func theWalkForAPageIsBounded() async throws {
        func nest(_ depth: Int) -> Node {
            depth == 0 ? Node(role: "AXGroup") : Node(role: "AXGroup", children: [nest(depth - 1)])
        }
        let window = Node(role: "AXWindow", children: (0..<32).map { _ in nest(12) })
        let box = Node(role: "AXTextField")
        box.editableAncestor = Node(role: "AXTextField")
        let world = world(application(menu: menuBar(), window: window), focused: box)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.browser == nil)
        #expect(world.asked.filter { $0 == .role }.count < 2 * BrowserMetadata.maxNodes)
    }

    // MARK: What it never does

    /// The probe reads where the selection is from, never the selection. A `metadataOnly` permit is
    /// enough for all of it.
    @Test func theSelectionItselfIsNeverRead() async throws {
        let page = Node(
            role: AXRole.webArea,
            selectedText: "the user's private text",
            title: "Example",
            url: URL(string: "https://example.com")
        )
        let world = world(application(menu: menuBar()), focused: page)
        _ = await contextProbe(world).probe(try permit())

        #expect(!world.asked.contains(.selectedText))
        #expect(!world.asked.contains(.selectedTextRange))
    }

    // MARK: Faults and bounds

    @Test func anAppWithNoAccessibilityTreeStillGivesAContext() async throws {
        let world = FakeAXWorld()
        world.setApplication(application(), in: target.pid)
        world.failApplication(target.pid, with: .notPermitted)
        let context = await contextProbe(world).probe(try permit())

        #expect(context.app.name == "Safari")
        #expect(context.fault == .notPermitted)
        #expect(!context.canCut)
        #expect(!context.canPaste)
        #expect(context.role == nil)
    }

    /// Every element the probe will talk to is bounded first, so a wedged app costs one timeout on
    /// this queue and nothing on any other.
    @Test func everyElementIsBoundedByTheReadBudget() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXTextField"))
        _ = await contextProbe(world).probe(try permit())

        #expect(world.timeouts == [readTimeout, readTimeout])
    }

    /// The Edit menu is walked once per process, whatever else changes between attempts.
    @Test func theMenuIsWalkedOnceAcrossAttempts() async throws {
        let world = world(application(menu: menuBar()), focused: Node(role: "AXTextField"))
        let probe = await contextProbe(world)
        _ = await probe.probe(try permit())
        let walked = world.asked.filter { $0 == .menuItemCmdChar }.count
        _ = await probe.probe(try permit())

        #expect(world.asked.filter { $0 == .menuItemCmdChar }.count == walked)

        await probe.forget(target.pid)
        _ = await probe.probe(try permit())
        #expect(world.asked.filter { $0 == .menuItemCmdChar }.count == walked * 2)
    }
}
