import Foundation
import PappuCore
import PappuSurfaces
import Testing

/// The one seam between the action list and the bar: a `CatalogAction` becoming a button (BAR-6).
///
/// Everything above this line is tested against facts (`ActionMatchingTests`) or against the files
/// that ship (`ActionResolverTests`); everything below it is geometry (`BarLayoutTests`). What is left
/// is the translation, and all of its decisions are about what to draw when the icon is not drawable.
@Suite struct BarItemCatalogTests {
    static func action(
        _ identifier: String = "a",
        title: LocalizedText? = "Copy",
        icon: ActionIcon = .specifier("symbol:doc.on.doc"),
        extensionIcon: ActionIcon = .unset,
        showAs: ExtensionManifest.ShowAs = .icon,
        wantsPrimaryDisplay: Bool = false
    ) -> CatalogAction {
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: ExtensionManifest(
                    name: "Ext",
                    identifier: "com.example.ext",
                    icon: extensionIcon,
                    showAs: showAs,
                    actions: [
                        ActionManifest(
                            title: title,
                            icon: icon,
                            identifier: identifier,
                            wantsPrimaryDisplay: wantsPrimaryDisplay,
                            executor: .builtin(.copy)
                        )
                    ]
                ),
                origin: .appBundle
            )
        ])
        return catalog.actions[0]
    }

    // MARK: Identity

    /// A click comes back from the bar as an id, and the catalog has to find the action again from it.
    @Test func aButtonIsNamedByItsActionsKey() {
        let item = BarItem(Self.action("copy"))
        #expect(item.id == BarItemID("com.example.ext#copy"))
        #expect(item.id == BarItemID(ActionKey(extensionIdentifier: "com.example.ext", action: "copy")))
    }

    // MARK: What gets drawn

    @Test func anSFSymbolIsDrawnAsOne() {
        #expect(BarItem(Self.action()).display == .icon(.symbol("doc.on.doc")))
    }

    @Test func aShortTextSpecifierIsDrawnInTheIconsPlace() {
        #expect(BarItem(Self.action(icon: .specifier("text:WC"))).display == .icon(.letters("WC")))
    }

    /// §8.3's `showAs: text` is the extension author saying "this one is a word, not a picture", and
    /// it wins over an icon that would otherwise have drawn.
    @Test func showAsTextDrawsTheNameEvenWhenThereIsAnIcon() {
        #expect(BarItem(Self.action(showAs: .text)).display == .text("Copy"))
    }

    /// The fallback that makes §8.11's unfinished half survivable: an icon form M1 cannot draw — a
    /// file in the package, Iconify, `svg:`, `data:` — becomes the action's name rather than a blank
    /// square, which is a button the user can still read and still click.
    @Test func anIconThisBuildCannotDrawBecomesTheName() {
        for specifier in ["iconify:mdi:home", "icon.png", "svg:<svg/>", "data:image/png;base64,AA"] {
            #expect(BarItem(Self.action(icon: .specifier(specifier))).display == .text("Copy"), "\(specifier)")
        }
    }

    /// `icon: null` is an answer (`ActionIcon.none`), and it means the same thing on the bar as an
    /// unreadable specifier: draw the word.
    @Test func anExplicitNoIconDrawsTheName() {
        #expect(BarItem(Self.action(icon: .none, extensionIcon: .specifier("symbol:star"))).display == .text("Copy"))
    }

    /// Inheritance is the catalog's job, not the bar's; this checks the bar sees the resolved answer.
    @Test func anActionWithNoIconOfItsOwnDrawsItsExtensions() {
        #expect(BarItem(Self.action(icon: .unset, extensionIcon: .specifier("symbol:star"))).display == .icon(.symbol("star")))
    }

    /// BAR-6 and BAR-14: the name is the tooltip and the VoiceOver label whatever the button draws, so
    /// an icon-only button is never unreachable or unnamed.
    @Test func anIconButtonStillCarriesItsName() {
        let item = BarItem(Self.action())
        #expect(item.name == "Copy")
        #expect(item.tooltip == "Copy")
    }

    // MARK: Language

    /// The machine's language is asked exactly once, here, and a caller that passes a locale gets the
    /// same answer on every machine — which is the only reason this test can exist.
    @Test func theNameIsResolvedForTheLocaleTheCallerMeans() {
        let action = Self.action(title: .localized(["en": "Copy", "fr": "Copier"]))
        #expect(BarItem(action, locale: Locale(identifier: "fr_FR")).name == "Copier")
        #expect(BarItem(action, locale: Locale(identifier: "de_DE")).name == "Copy")
    }

    // MARK: Flags that ride along

    /// BAR-4. M4 places the bar with it; M1's job is only not to lose it between the file and the bar.
    @Test func theRequestToSitUnderThePointerSurvivesTheTrip() {
        #expect(BarItem(Self.action(wantsPrimaryDisplay: true)).wantsPrimaryDisplay)
        #expect(BarItem(Self.action()).wantsPrimaryDisplay == false)
    }

    // MARK: The bar as a whole

    /// ALM-1 at the last place it could be broken: the bar builds every action it is given. What fits
    /// is `BarLayout`'s question and the overflow is BAR-5a's, and neither is answered by dropping
    /// buttons here.
    @Test func theBarBuildsEveryActionItIsGivenInOrder() {
        let manifest = ExtensionManifest(
            name: "Many",
            identifier: "com.example.many",
            actions: (0..<500).map {
                ActionManifest(title: LocalizedText("Action \($0)"), identifier: "a\($0)", executor: .builtin(.copy))
            }
        )
        let catalog = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)])
        let content = BarContent(actions: catalog.actions, locale: Locale(identifier: "en_US"))
        #expect(content.count == 500)
        #expect(content.items.map(\.id) == catalog.actions.map { BarItemID($0.key) })
    }

    @Test func aBarWithNothingToShowIsEmptyRatherThanAbsent() {
        #expect(BarContent(actions: []).isEmpty)
    }
}
