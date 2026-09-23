import Foundation
import PappuCore
import Testing

/// The M1 manifest model: what §8.3 says a file may hold, and the one rule that makes the reserved
/// `builtin` executor safe to have at all (architecture §19 item 2).
@Suite struct ExtensionManifestTests {
    static func decode(_ json: String) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    // MARK: LocalizedText

    @Test func aPlainStringAndALanguageTableBothMeanAString() throws {
        #expect(try JSONDecoder().decode(LocalizedText.self, from: Data(#""Copy""#.utf8)).english == "Copy")
        #expect(try JSONDecoder().decode(LocalizedText.self, from: Data(#"{"en":"Copy","fr":"Copier"}"#.utf8)).english == "Copy")
    }

    @Test func aTableWithNoEnglishDoesNotDecode() {
        #expect(throws: LocalizedText.MissingEnglish.self) {
            try JSONDecoder().decode(LocalizedText.self, from: Data(#"{"fr":"Copier"}"#.utf8))
        }
    }

    /// An author who wrote one string gets one string back, which is what View Source and the
    /// registry's diff both depend on.
    @Test func eachFormKeepsTheShapeItArrivedIn() throws {
        for json in [#""Copy""#, #"{"en":"Copy","fr":"Copier"}"#] {
            let value = try JSONDecoder().decode(LocalizedText.self, from: Data(json.utf8))
            let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            #expect(try JSONDecoder().decode(LocalizedText.self, from: Data(encoded.utf8)) == value, "\(json)")
        }
    }

    @Test func aLanguageTableAnswersTheClosestLanguageItHas() throws {
        let text = try JSONDecoder().decode(LocalizedText.self, from: Data(#"{"en":"Copy","pt":"Copiar"}"#.utf8))
        #expect(text.text(for: ["pt-BR"]) == "Copiar")
        #expect(text.text(for: ["de"]) == "Copy")
    }

    // MARK: Defaults

    @Test func anActionWithNoRequirementsRequiresASelection() throws {
        let manifest = try Self.decode("""
        {"name":"T","identifier":"com.example.t","actions":[{"executor":{"builtin":"copy"}}]}
        """)
        #expect(manifest.actions[0].requirements == [.text])
    }

    /// An explicit empty list is an answer, not a missing key: the action asks for nothing.
    @Test func anExplicitlyEmptyRequirementListMeansNone() throws {
        let manifest = try Self.decode("""
        {"name":"T","identifier":"com.example.t","actions":[{"requirements":[],"executor":{"builtin":"copy"}}]}
        """)
        #expect(manifest.actions[0].requirements.isEmpty)
    }

    /// §8.3 spells one action `action` and several `actions`. Both are read.
    @Test func bothSpellingsOfTheActionKeyAreRead() throws {
        let single = try Self.decode("""
        {"name":"T","identifier":"com.example.t","action":{"executor":{"builtin":"copy"}}}
        """)
        #expect(single.actions.count == 1)
        let both = try Self.decode("""
        {"name":"T","identifier":"com.example.t",
         "action":{"identifier":"a","executor":{"builtin":"copy"}},
         "actions":[{"identifier":"b","executor":{"builtin":"cut"}}]}
        """)
        #expect(both.actions.map(\.identifier) == ["a", "b"])
    }

    // MARK: Icons

    /// The distinction the whole `ActionIcon` type exists for.
    @Test func noIconKeyAndAnExplicitNullAreDifferentAnswers() throws {
        let absent = try Self.decode("""
        {"name":"T","identifier":"com.example.t","icon":"symbol:star","actions":[{"executor":{"builtin":"copy"}}]}
        """)
        #expect(absent.actions[0].icon == .unset)
        let explicit = try Self.decode("""
        {"name":"T","identifier":"com.example.t","icon":"symbol:star","actions":[{"icon":null,"executor":{"builtin":"copy"}}]}
        """)
        #expect(explicit.actions[0].icon == .none)
    }

    @Test func anActionInheritsTheExtensionsIconAndAnExplicitNoneStopsTheWalk() {
        #expect(ActionIcon.unset.resolved(orInheriting: .specifier("symbol:star")) == .specifier("symbol:star"))
        #expect(ActionIcon.none.resolved(orInheriting: .specifier("symbol:star")) == .none)
        #expect(ActionIcon.specifier("symbol:a").resolved(orInheriting: .specifier("symbol:b")) == .specifier("symbol:a"))
    }

    @Test func theSpecifierFormsThisBuildReads() {
        #expect(IconSpec(parsing: "symbol:doc.on.doc") == .symbol("doc.on.doc"))
        #expect(IconSpec(parsing: "text:AB") == .text("AB"))
        #expect(IconSpec(parsing: "AB") == .text("AB"))
        #expect(IconSpec(parsing: "ABC") == .text("ABC"))
    }

    /// Nothing is silently dropped: a form M1 does not render is kept whole so the bar can fall back
    /// to the title and M2 can read it without a format change.
    @Test func aFormThisBuildDoesNotRenderIsKeptWhole() {
        #expect(IconSpec(parsing: "iconify:mdi:home") == .unread("iconify:mdi:home"))
        #expect(IconSpec(parsing: "icon.png") == .unread("icon.png"))
        #expect(IconSpec(parsing: "ABCD") == .unread("ABCD"))
    }

    // MARK: The reserved executor

    /// The one rule that makes a native implementation chosen by a string in a file safe to have.
    @Test func onlyTheAppsOwnBundleMayNameTheBuiltinExecutor() throws {
        let manifest = try Self.decode("""
        {"name":"T","identifier":"com.example.t","actions":[{"executor":{"builtin":"paste"}}]}
        """)
        #expect(throws: Never.self) { try manifest.validate(origin: .appBundle) }
        #expect(throws: ExtensionManifest.Invalid.self) { try manifest.validate(origin: .installed) }
    }

    /// The check is on the origin, which the loader knows, and never on the identifier, which the file
    /// can say whatever it likes about.
    @Test func claimingOurIdentifierDoesNotEarnTheReservedExecutor() throws {
        let manifest = try Self.decode("""
        {"name":"T","identifier":"app.pappuclip.builtin.paste","actions":[{"executor":{"builtin":"paste"}}]}
        """)
        #expect(throws: ExtensionManifest.Invalid.self) { try manifest.validate(origin: .installed) }
    }

    /// FMT-6, separately from the executor: the reserved prefix belongs to extensions our directory
    /// signs, whatever they run.
    @Test func theReservedIdentifierPrefixIsRefusedFromAnywhereElse() throws {
        let manifest = try Self.decode("""
        {"name":"T","identifier":"app.pappuclip.pretender","actions":[{"executor":{"builtin":"copy"}}]}
        """)
        let error = #expect(throws: ExtensionManifest.Invalid.self) { try manifest.validate(origin: .installed) }
        #expect(error?.reason == .reservedIdentifierPrefix)
    }

    @Test func anExtensionWithNoActionsIsRefused() throws {
        let manifest = try Self.decode(#"{"name":"T","identifier":"com.example.t"}"#)
        let error = #expect(throws: ExtensionManifest.Invalid.self) { try manifest.validate(origin: .appBundle) }
        #expect(error?.reason == .noActions)
    }

    /// M2 adds six executor types. Until the code that runs one exists, a manifest naming it is
    /// refused at load with a message rather than shown as a button that does nothing.
    @Test func anExecutorThisBuildCannotRunDoesNotDecode() {
        #expect(throws: (any Error).self) {
            try Self.decode("""
            {"name":"T","identifier":"com.example.t","actions":[{"shellScript":"ls"}]}
            """)
        }
    }
}
