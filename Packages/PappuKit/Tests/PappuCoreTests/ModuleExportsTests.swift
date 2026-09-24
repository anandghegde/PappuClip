import Foundation
@testable import PappuCore
import Testing

/// JS-12: a module extension's actions are what its module exported, read with a config's rules, and
/// every one of them runs the module's code.
@Suite struct ModuleExportsTests {
    static let snippet = "// #popclip\n// name: Moduled\n// after: copy-result\ndefineExtension({ actions: [] })"

    static func exports(_ json: String, functions: [String] = []) throws -> ModuleExports {
        try ModuleExports(json: json, functions: functions)
    }

    static func load(_ json: String, functions: [String] = [], snippet: String = snippet) throws -> ExtensionLoader.Loaded {
        try ExtensionLoader.loadSnippet(snippet, settings: .init(moduleExports: try exports(json, functions: functions)))
    }

    static func script(_ action: ActionManifest) -> JavaScriptAction? {
        if case .javaScript(let script) = action.executor { return script }
        return nil
    }

    @Test func aModuleHasNoActionsUntilItIsDescribed() throws {
        let loaded = try ExtensionLoader.loadSnippet(Self.snippet)
        #expect(loaded.manifest.actions.isEmpty)
        #expect(loaded.manifest.moduleSource == ModuleSource(source: .inline(Self.snippet), isTypeScript: true))
    }

    @Test func eachDescribedActionRunsTheCodeAtItsExport() throws {
        let json = #"{"actions":[{"title":"One","code":true},{"code":true,"identifier":"two"}],"action":{"title":"Solo","code":true}}"#
        let manifest = try Self.load(json).manifest
        #expect(manifest.actions.map { $0.title?.english } == ["Solo", "One", nil])
        #expect(manifest.actions.map { Self.script($0)?.export } == ["action", "actions.0", "actions.1"])
        #expect(manifest.actions.allSatisfy { Self.script($0)?.source == .inline(Self.snippet) })
        #expect(manifest.actions.allSatisfy { Self.script($0)?.isTypeScript == true })
        #expect(manifest.actions.map(\.identifier) == [nil, nil, "two"])
    }

    @Test func theModulesKeysAreDefaultsOverTheConfigs() throws {
        // The config's header says copy-result; the module's top level says paste-result; the last
        // action says its own.
        let json = #"{"after":"paste-result","requirements":["url"],"actions":[{"code":true},{"code":true,"after":"show-result"}]}"#
        let manifest = try Self.load(json).manifest
        #expect(manifest.actions.map(\.after) == [.pasteResult, .showResult])
        #expect(manifest.actions.map(\.requirements) == [[ActionRequirement(parsing: "url")], [ActionRequirement(parsing: "url")]])
        #expect(try Self.load(#"{"actions":[{"code":true}]}"#).manifest.actions.map(\.after) == [.copyResult])
    }

    @Test func aJavaScriptRegexArrivesAsAnICUPatternAndIsChecked() throws {
        let manifest = try Self.load(#"{"regex":"(?i)^[a-z]+$","action":{"code":true}}"#).manifest
        #expect(manifest.actions.map(\.regex) == ["(?i)^[a-z]+$"])
    }

    @Test func whatOnlyAConfigMaySetIsIgnoredAndSaid() throws {
        let loaded = try Self.load(#"{"name":"Other","identifier":"com.example.other","entitlements":["network"],"action":{"code":true}}"#)
        #expect(loaded.manifest.name.english == "Moduled")
        #expect(loaded.manifest.identifier == "Moduled")
        #expect(loaded.manifest.entitlements.isEmpty)
        #expect(loaded.warnings.map(\.path) == ["module.name", "module.identifier", "module.entitlements"])
    }

    @Test func aPopulationFunctionOffersNothingYetAndSaysWhy() throws {
        let loaded = try Self.load(#"{"options":[]}"#, functions: ["actions", "test"])
        #expect(loaded.manifest.actions.isEmpty)
        #expect(loaded.warnings.map(\.path) == ["module.actions"])
    }

    /// The helper writes `code: true` only for a function; nothing else in the data can stand for one.
    @Test func anActionWithNoCodeIsLeftOut() throws {
        let json = #"{"actions":[{"title":"Label"},{"separator":true},{"title":"Real","code":true},{"title":"Forged","code":1}]}"#
        let loaded = try Self.load(json)
        #expect(loaded.manifest.actions.map { Self.script($0)?.export } == ["actions.2"])
        #expect(loaded.warnings.map(\.path) == ["module.actions[0]", "module.actions[1]", "module.actions[3]"])
    }

    @Test func anActionTypeInAModuleIsIgnoredAndItsCodeRuns() throws {
        let loaded = try Self.load(#"{"action":{"code":true,"url":"https://example.com/***"},"keyCombo":"command b"}"#)
        #expect(loaded.manifest.actions.map { Self.script($0)?.export } == ["action"])
        #expect(Set(loaded.warnings.map(\.path)) == ["module.keyCombo", "module.action.url"])
    }

    @Test func theModulesOptionsReplaceTheConfigs() throws {
        let snippet = "// #popclip\n// name: Moduled\n// options: [{identifier: a, type: string}]\ndefineExtension({})"
        let loaded = try Self.load(#"{"options":[{"identifier":"b","type":"boolean"}],"action":{"code":true}}"#, snippet: snippet)
        #expect(loaded.manifest.options.map(\.identifier) == ["b"])
    }

    @Test func aModuleWithoutActionsLeavesTheConfigs() throws {
        let package = try Fixture.package(files: [
            "Config.json": #"{"name": "P", "module": "m.js", "url": "https://example.com/?q=***"}"#,
            "m.js": "module.exports = {}",
        ])
        let loaded = try ExtensionLoader.loadPackage(at: package.root, settings: .init(moduleExports: Self.exports(#"{"options":[]}"#)))
        #expect(loaded.manifest.moduleSource == ModuleSource(source: .file("m.js"), isTypeScript: false))
        #expect(loaded.manifest.actions.map(\.executor.kind) == [.url])
    }

    @Test func aPackagesCodeConfigIsItsOwnModule() throws {
        let typeScript = try Fixture.package(files: ["Config.ts": "// #popclip\n// name: T\nexport default { action: { code: () => 'x' } }"])
        #expect(try ExtensionLoader.loadPackage(at: typeScript.root).manifest.moduleSource == ModuleSource(source: .file("Config.ts"), isTypeScript: true))
        let javaScript = try Fixture.package(files: ["Config.js": "// #popclip\n// name: J\nmodule.exports = { action: () => 'x' }"])
        #expect(try ExtensionLoader.loadPackage(at: javaScript.root).manifest.moduleSource == ModuleSource(source: .file("Config.js"), isTypeScript: false))
    }

    @Test func aScriptIsNotAModuleWhateverItIsHanded() throws {
        let settings = ExtensionLoader.Settings(moduleExports: try Self.exports(#"{"action":{"code":true}}"#))
        let loaded = try ExtensionLoader.loadSnippet("// #popclip\n// name: S\nreturn popclip.input.text", settings: settings)
        #expect(loaded.manifest.moduleSource == nil)
        #expect(loaded.manifest.actions.map { Self.script($0)?.export } == [nil])
    }

    @Test func exportsThatBreakTheRulesFailTheLoad() {
        #expect(throws: ManifestLoadFailure.self) { try Self.load(#"{"action":{"code":true,"regex":"("}}"#) }
        #expect(throws: ManifestLoadFailure.self) { try Self.load(#"{"action":{"code":true,"before":"copy-result"}}"#) }
        #expect(throws: ManifestLoadFailure.self) { try Self.load(#"{"submenu":[{"code":true}]}"#) }
        #expect(throws: ManifestLoadFailure.self) { try Self.load("[1, 2]") }
    }

    @Test func theHelpersJSONIsReadInTheOrderItWasWritten() throws {
        let exports = try Self.exports(#"{"b":1,"a":{"z":"x","y":[true,null,1.5]}}"#)
        #expect(exports.object == ["b": 1, "a": ["z": "x", "y": [true, nil, .double(1.5)]]])
    }
}
