import Foundation
import PappuCore
import Testing

/// The action list as a value (ALM-1, ALM-3, ALM-4).
@Suite struct ActionCatalogTests {
    static func manifest(
        _ identifier: String,
        name: LocalizedText = "Ext",
        icon: ActionIcon = .unset,
        showAs: ExtensionManifest.ShowAs = .icon,
        actions: [ActionManifest]
    ) -> ExtensionManifest {
        ExtensionManifest(name: name, identifier: identifier, icon: icon, showAs: showAs, actions: actions)
    }

    static func action(
        _ identifier: String? = nil,
        title: LocalizedText? = nil,
        icon: ActionIcon = .unset,
        executor: ActionExecutor = .builtin(.copy)
    ) -> ActionManifest {
        ActionManifest(title: title, icon: icon, identifier: identifier, executor: executor)
    }

    // MARK: ALM-1

    /// **ALM-1: there is no limit on the number of actions.**
    ///
    /// Two thousand is not a realistic library; it is far past any bar's width, any window's height
    /// and any number a `prefix` somebody added to make a screen look right would have used. If this
    /// ever fails, a cap was introduced somewhere between a manifest and the list, which is the only
    /// way this requirement is ever broken.
    @Test func thereIsNoLimitOnTheNumberOfActions() {
        let actions = (0..<2_000).map { Self.action("a\($0)", title: LocalizedText("Action \($0)")) }
        let catalog = ActionCatalog(entries: [
            .init(manifest: Self.manifest("com.example.many", actions: actions), origin: .installed)
        ])
        #expect(catalog.count == 2_000)
        #expect(catalog.actions.map(\.key.action) == actions.map { $0.identifier! })
        #expect(catalog.enabled.count == 2_000)
        #expect(catalog[ActionKey(extensionIdentifier: "com.example.many", action: "a1999")] != nil)
    }

    /// The default order is the order the extensions were loaded, and within one extension the order
    /// its file lists them in (ALM-3).
    @Test func theCatalogKeepsTheOrderItWasGiven() {
        let catalog = ActionCatalog(entries: [
            .init(manifest: Self.manifest("com.example.a", actions: [Self.action("one"), Self.action("two")]), origin: .installed),
            .init(manifest: Self.manifest("com.example.b", actions: [Self.action("three")]), origin: .installed),
        ])
        #expect(catalog.actions.map(\.key.description) == [
            "com.example.a#one", "com.example.a#two", "com.example.b#three",
        ])
    }

    // MARK: Keys

    /// Two extensions may both call an action `copy`, so an action's own identifier cannot be its key.
    @Test func anActionIsNamedByItsExtensionAndItself() {
        let catalog = ActionCatalog(entries: [
            .init(manifest: Self.manifest("com.example.a", actions: [Self.action("copy")]), origin: .installed),
            .init(manifest: Self.manifest("com.example.b", actions: [Self.action("copy")]), origin: .installed),
        ])
        #expect(Set(catalog.actions.map(\.key)).count == 2)
    }

    /// An action with no identifier of its own is keyed by its position, which is stable for as long
    /// as the file is.
    @Test func anActionWithNoIdentifierIsKeyedByItsPosition() {
        let catalog = ActionCatalog(entries: [
            .init(manifest: Self.manifest("com.example.a", actions: [Self.action(), Self.action()]), origin: .installed)
        ])
        #expect(catalog.actions.map(\.key.action) == ["0", "1"])
    }

    // MARK: Inheritance, resolved once

    @Test func anActionWithNoTitleIsCalledAfterItsExtension() {
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: Self.manifest("com.example.a", name: "Word Count", actions: [Self.action(), Self.action(title: "Chars")]),
                origin: .installed
            )
        ])
        #expect(catalog.actions.map { $0.title.english } == ["Word Count", "Chars"])
    }

    @Test func anActionWithNoIconTakesTheExtensionsAndTheExtensionTakesItsFirstActions() {
        let inherited = ActionCatalog(entries: [
            .init(
                manifest: Self.manifest("com.example.a", icon: .specifier("symbol:star"), actions: [Self.action(), Self.action(icon: .specifier("symbol:bolt"))]),
                origin: .installed
            )
        ])
        #expect(inherited.actions.map(\.icon) == [.specifier("symbol:star"), .specifier("symbol:bolt")])

        // §8.3's other direction: an extension with no icon shows its first action's.
        let fromFirstAction = ActionCatalog(entries: [
            .init(
                manifest: Self.manifest("com.example.b", actions: [Self.action(icon: .specifier("symbol:bolt")), Self.action()]),
                origin: .installed
            )
        ])
        #expect(fromFirstAction.actions.map(\.icon) == [.specifier("symbol:bolt"), .specifier("symbol:bolt")])
    }

    /// An explicit `icon: null` is an answer, and inheriting over it would turn a deliberate text
    /// button into an accidental icon.
    @Test func anExplicitNoIconIsNotOverwrittenByInheritance() {
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: Self.manifest("com.example.a", icon: .specifier("symbol:star"), actions: [Self.action(icon: .none)]),
                origin: .installed
            )
        ])
        #expect(catalog.actions[0].icon == .none)
    }

    // MARK: ALM-4

    /// A disabled extension keeps its place in the list. It is not offered; it is not gone.
    @Test func disablingAnExtensionKeepsItsActionsInTheList() {
        let catalog = ActionCatalog(entries: [
            .init(manifest: Self.manifest("com.example.a", actions: [Self.action("one")]), origin: .installed, isEnabled: false),
            .init(manifest: Self.manifest("com.example.b", actions: [Self.action("two")]), origin: .installed),
        ])
        #expect(catalog.count == 2)
        #expect(catalog.enabled.map(\.key.action) == ["two"])
    }

    @Test func aCatalogKnowsWhichOfItsActionsAreBuiltIn() {
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: Self.manifest("app.pappuclip.builtin.cut", actions: [Self.action("cut", executor: .builtin(.cut))]),
                origin: .appBundle
            )
        ])
        #expect(catalog.actions[0].builtin == .cut)
        #expect(catalog.actions[0].origin == .appBundle)
    }

    /// EXM-5f: a JavaScript action the scan bounds needs no `unbounded-code`; the rules its requests are
    /// checked by travel with it (JS-8).
    @Test func aScannedActionCarriesItsGatesAndItsNetwork() {
        let manifest = ExtensionManifest(
            name: "Fetch",
            identifier: "com.example.fetch",
            entitlements: [.network],
            networkHosts: ["api.example.com"],
            actions: [ActionManifest(identifier: "a", executor: .javaScript(JavaScriptAction(source: .inline("return 1"))))]
        )
        let unscanned = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
        #expect(unscanned.gates == [.unboundedCode])
        let bounded = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed, scan: CodeScan(methods: ["XMLHttpRequest"]))]).actions[0]
        #expect(bounded.gates.isEmpty)
        #expect(bounded.network == NetworkPolicy(hosts: ["api.example.com"]))
        #expect(bounded.entitlements == [.network])
    }
}
