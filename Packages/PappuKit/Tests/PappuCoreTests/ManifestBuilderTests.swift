import Foundation
import PappuCore
import Testing

/// §8.1–8.4 and FMT-3/5/6: config values to a checked manifest.
@Suite struct ManifestBuilderTests {
    // MARK: Helpers

    static func build(_ yaml: String, package: PackageFiles? = nil, ignoresAPILevel: Bool = false) throws -> ManifestBuilder.Built {
        try ManifestBuilder.build(.init(config: ConfigDecoding.decodeYAML(yaml), package: package, ignoresAPILevel: ignoresAPILevel))
    }

    /// The load's errors, joined, or nil when it loaded.
    static func errors(_ yaml: String, package: PackageFiles? = nil) -> String? {
        do {
            _ = try build(yaml, package: package)
            return nil
        } catch let failure as ManifestLoadFailure {
            return failure.description
        } catch {
            return String(describing: error)
        }
    }

    static func warnings(_ yaml: String) throws -> String {
        try build(yaml).warnings.map(\.description).joined(separator: "\n")
    }

    // MARK: Shape

    @Test func aMinimalExtensionLoadsWithDefaults() throws {
        let manifest = try Self.build("name: Search\nurl: https://example.com/?q=***").manifest
        #expect(manifest.identifier == "Search")
        #expect(manifest.identifierOrigin == .name)
        #expect(manifest.actions.count == 1)
        #expect(manifest.actions[0].executor == .url(URLAction(template: "https://example.com/?q=***")))
        #expect(manifest.actions[0].requirements == [.text])
    }

    @Test func aNameIsRequired() {
        #expect(Self.errors("url: https://example.com") != nil)
    }

    @Test func legacySpellingsReadTheSameKeys() throws {
        let manifest = try Self.build("""
        Extension Name: A
        Extension Identifier: com.example.a
        Actions:
          - Title: Go
            Regular Expression: "\\\\d+"
            Blocked Apps: [com.example.x]
            Shell Script File: run.sh
            Script Interpreter: /bin/zsh
        """, package: try Fixture.package(files: ["run.sh": "echo"])).manifest
        #expect(manifest.identifier == "com.example.a")
        #expect(manifest.identifierOrigin == .declared)
        let action = manifest.actions[0]
        #expect(action.regex == "\\d+")
        #expect(action.excludedApps == ["com.example.x"])
        #expect(action.executor == .shellScript(ShellScriptAction(source: .file("run.sh"), interpreter: "/bin/zsh")))
    }

    // MARK: Inheritance

    @Test func topLevelKeysAreEachActionsDefaults() throws {
        let manifest = try Self.build("""
        name: A
        requirements: [url]
        url: https://a.example/***
        actions:
          - title: One
          - title: Two
            requirements: [text]
            url: https://b.example/***
          - title: Three
            serviceName: Make Sticky
        """).manifest
        #expect(manifest.actions.map(\.requirements) == [["url"], ["text"], ["url"]].map { $0.map(ActionRequirement.init(parsing:)) })
        #expect(manifest.actions[0].executor == .url(URLAction(template: "https://a.example/***")))
        #expect(manifest.actions[1].executor == .url(URLAction(template: "https://b.example/***")))
        // An action with its own type does not inherit another type's key.
        #expect(manifest.actions[2].executor == .service(ServiceAction(name: "Make Sticky")))
    }

    @Test func anActionWithTwoTypesIsRefused() {
        let message = Self.errors("name: A\nactions:\n  - title: X\n    url: https://a.example\n    serviceName: S")
        #expect(message?.contains("several") == true)
    }

    @Test func anActionWithNoTypeIsRefused() {
        #expect(Self.errors("name: A\nactions:\n  - title: X")?.contains("no action type") == true)
    }

    // MARK: API level (§8.3)

    @Test func aNewerPopClipVersionIsRefusedUnlessOverridden() throws {
        let yaml = "name: A\npopclipVersion: \(APILevel.emulatedPopClip + 1)\nurl: https://a.example"
        #expect(Self.errors(yaml) != nil)
        let built = try Self.build(yaml, ignoresAPILevel: true)
        #expect(built.warnings.contains { $0.message.contains("debug override") })
        #expect(Self.errors("name: A\npopclipVersion: \(APILevel.emulatedPopClip)\nurl: https://a.example") == nil)
    }

    @Test func aNewerPappuClipVersionIsRefused() {
        #expect(Self.errors("name: A\npappuclipVersion: \(APILevel.native + 1)\nurl: https://a.example") != nil)
    }

    // MARK: Entitlements

    @Test func dynamicCannotBeCombinedWithNetworkOrScript() {
        #expect(Self.errors("name: A\nentitlements: [dynamic, network]\nurl: https://a.example") != nil)
        #expect(Self.errors("name: A\nentitlements: [dynamic]\nurl: https://a.example") == nil)
        #expect(Self.errors("name: A\nentitlements: [telepathy]\nurl: https://a.example") != nil)
    }

    // MARK: Steps

    @Test func beforeIsOnlyAnEditingStep() throws {
        #expect(try Self.build("name: A\nbefore: copy\nafter: paste-result\nkeyCombo: command b").manifest.actions[0].before == .copy)
        #expect(Self.errors("name: A\nbefore: paste-result\nkeyCombo: command b")?.contains("only come after") == true)
        #expect(Self.errors("name: A\nafter: dance\nkeyCombo: command b") != nil)
    }

    // MARK: Refusals that name their milestone

    @Test func anInvalidRegexIsRefused() {
        #expect(Self.errors("name: A\nregex: \"([a-z\"\nurl: https://a.example")?.contains("does not compile") == true)
    }

    @Test func submenusAndPappuAfterAreRefusedUntilTheyExist() {
        #expect(Self.errors("name: A\nactions:\n  - title: X\n    url: https://a.example\n    submenu: []")?.contains("M4") == true)
        #expect(Self.errors("name: A\nactions:\n  - title: X\n    url: https://a.example\n    pappuAfter: rich")?.contains("M3") == true)
    }

    // MARK: Key presses

    @Test func keyCombosTakeStringsWaitsAndLegacyDictionaries() throws {
        let manifest = try Self.build("""
        name: A
        keyCombos:
          - command c
          - wait 200
          - {keyCode: 9, modifiers: 1048576}
        """).manifest
        #expect(manifest.actions[0].executor == .keyPress(KeyPressAction(steps: [
            .combo("command c"), .wait(milliseconds: 200), .legacyCombo(keyCode: 9, keyCharacter: nil, modifiers: 1_048_576),
        ])))
        #expect(Self.errors("name: A\nkeyCombo: command c\nkeyCombos: [command v]") != nil)
        #expect(Self.errors("name: A\nkeyCombo: wait 200") != nil)
    }

    @Test func aComboThatCannotBePressedRefusesTheExtensionAtLoad() {
        #expect(Self.errors("name: A\nkeyCombo: hyper b")?.contains("not a modifier") == true)
        #expect(Self.errors("name: A\nkeyCombo: command enter")?.contains("not a key") == true)
        #expect(Self.errors("name: A\nkeyCombos: [{keyCode: 300, modifiers: 0}]") != nil)
    }

    // MARK: Files (FMT-3, §8.4)

    @Test func aSnippetCannotReferToFiles() {
        #expect(Self.errors("name: A\nshellScriptFile: run.sh")?.contains("FMT-3") == true)
        #expect(Self.errors("name: A\nicon: icon.png\nurl: https://a.example")?.contains("FMT-3") == true)
    }

    @Test func aPackageFileMustBeInsideAndPresent() throws {
        let package = try Fixture.package(files: ["run.sh": "echo"])
        #expect(Self.errors("name: A\nshellScriptFile: ../run.sh", package: package)?.contains("outside") == true)
        #expect(Self.errors("name: A\nshellScriptFile: /etc/hosts", package: package)?.contains("outside") == true)
        #expect(Self.errors("name: A\nshellScriptFile: gone.sh", package: package)?.contains("not in the package") == true)
    }

    @Test func aShellFileNeedsAnInterpreterAShebangOrTheShDefault() throws {
        let package = try Fixture.package(
            files: ["run.sh": "echo", "run.py": "print(1)", "tool": "#!/usr/bin/env python3\nprint(1)"],
            executable: ["tool"]
        )
        // `.sh` runs under /bin/sh.
        let sh = try Self.build("name: A\npopclipVersion: 5000\nshellScriptFile: run.sh", package: package).manifest
        #expect(sh.actions[0].executor == .shellScript(ShellScriptAction(source: .file("run.sh"), interpreter: "/bin/sh")))
        // An executable with #! runs as itself.
        #expect(Self.errors("name: A\npopclipVersion: 5000\nshellScriptFile: tool", package: package) == nil)
        // Anything else needs an interpreter, unless the manifest predates PopClip 4035.
        #expect(Self.errors("name: A\npopclipVersion: 5000\nshellScriptFile: run.py", package: package) != nil)
        #expect(Self.errors("name: A\npopclipVersion: 5000\ninterpreter: python3\nshellScriptFile: run.py", package: package) == nil)
        #expect(Self.errors("name: A\nshellScriptFile: run.py", package: package) == nil)
    }

    // MARK: Identifiers (FMT-6)

    @Test func aDeclaredIdentifierMustBeWellFormed() {
        #expect(Self.errors("name: A\nidentifier: -bad\nurl: https://a.example")?.contains("must start and end") == true)
        #expect(Self.errors("name: A\nidentifier: com..x\nurl: https://a.example") != nil)
        #expect(Self.errors("name: A\nidentifier: com.example/x\nurl: https://a.example") != nil)
        // A name used as the identifier is not held to the rules.
        #expect(Self.errors("name: My Extension!\nurl: https://a.example") == nil)
    }

    // MARK: Warnings

    @Test func unknownKeysWarnAndLegacyMetadataDoesNot() throws {
        let warnings = try Self.warnings("name: A\ncredits: someone\nversion: 3\nflavour: mint\nurl: https://a.example")
        #expect(warnings.contains("flavour"))
        #expect(!warnings.contains("credits"))
        #expect(!warnings.contains("version"))
    }

    @Test func removedKeysSaySo() throws {
        #expect(try Self.warnings("name: A\nstoppable: true\nurl: https://a.example").contains("no longer"))
    }

    @Test func legacyIconModifierKeysFoldIntoTheSpecifier() throws {
        let manifest = try Self.build("""
        name: A
        actions:
          - title: X
            icon: symbol:star
            flipHorizontal: true
            preserveImageColor: true
            iconOptions: {scale: 2}
            url: https://a.example
        """).manifest
        let specifier = try #require(manifest.actions[0].icon.specifier)
        #expect(specifier.hasSuffix("symbol:star"))
        for modifier in ["flip-x", "preserve-color", "scale=2"] {
            #expect(specifier.contains(modifier))
        }
    }

    @Test func aHTMLRequirementIsDroppedWithAWarning() throws {
        let built = try Self.build("name: A\nrequirements: [text, html]\nurl: https://a.example")
        #expect(built.manifest.actions[0].requirements == [.text])
        #expect(built.warnings.contains { $0.message.contains("html") })
    }

    // MARK: Options

    @Test func optionsNeedATypeAndAUniqueIdentifier() {
        #expect(Self.errors("name: A\noptions:\n  - identifier: x\nurl: https://a.example") != nil)
        #expect(Self.errors("name: A\noptions:\n  - {identifier: x, type: string}\n  - {identifier: x, type: boolean}\nurl: https://a.example") != nil)
        #expect(Self.errors("name: A\noptions:\n  - {type: heading, label: Section}\nurl: https://a.example") == nil)
        #expect(Self.errors("name: A\noptions:\n  - {identifier: x, type: multiple}\nurl: https://a.example") != nil)
    }
}

/// A temporary package folder.
enum Fixture {
    static func package(files: [String: String], executable: Set<String> = []) throws -> PackageFiles {
        let root = FileManager.default.temporaryDirectory.appending(path: "pappu-fixture-\(UUID().uuidString).popclipext")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files {
            let url = root.appending(path: name)
            try Data(text.utf8).write(to: url)
            if executable.contains(name) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return PackageFiles(root: root)
    }
}
