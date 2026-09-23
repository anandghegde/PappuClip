import Foundation
import PappuCore
import Testing

/// FMT-1 and FMT-2: finding the config in a snippet.
@Suite struct SnippetDetectorTests {
    @Test(arguments: ["#popclip", "# popclip", "#PopClip", "#pappuclip", "# PappuClip extension", "#popclip: a comment"])
    func theMarkerIsCaseInsensitiveWithAnOptionalSpace(_ marker: String) {
        #expect(SnippetDetector.detect("\(marker)\nname: A") == .config(yaml: "name: A"))
    }

    @Test(arguments: ["#popclipper\nname: A", "name: A\n#popclip", "popclip\nname: A", ""])
    func textWithoutALeadingMarkerIsNotASnippet(_ text: String) {
        #expect(SnippetDetector.detect(text) == nil)
    }

    @Test func aByteOrderMarkAndCRLFLineEndingsAreIgnored() {
        #expect(SnippetDetector.detect("\u{FEFF}#popclip\r\nname: A\r\nurl: x") == .config(yaml: "name: A\nurl: x"))
    }

    @Test func aCodeSnippetsHeaderIsTheCommentRunAfterTheMarker() throws {
        let text = "// #popclip\n// name: A\n//   language: javascript\nreturn popclip.input.text;"
        guard case .code(let yaml, let body) = SnippetDetector.detect(text) else {
            Issue.record("not a code snippet")
            return
        }
        #expect(yaml == "name: A\n  language: javascript")
        #expect(body.style == .slashes)
        #expect(body.text == text)
    }

    @Test func aShebangAndCommentsMayComeBeforeTheMarker() throws {
        let text = "#!/bin/zsh\n# a script\n\n# #popclip\n# name: A\necho hi"
        guard case .code(let yaml, let body) = SnippetDetector.detect(text) else {
            Issue.record("not a code snippet")
            return
        }
        #expect(yaml == "name: A")
        #expect(body.style == .hash)
        #expect(body.shebang == "/bin/zsh")
    }

    @Test func aMarkerAfterCodeIsJustText() {
        #expect(SnippetDetector.detect("echo hi\n# #popclip\n# name: A") == nil)
    }

    @Test func aDashedHeaderIsAppleScript() {
        guard case .code(_, let body) = SnippetDetector.detect("-- #popclip\n-- name: A\nreturn 1") else {
            Issue.record("not a code snippet")
            return
        }
        #expect(body.style == .dashes)
    }

    @Test func aSelectionOverTheLimitIsNotOffered() {
        let long = "#popclip\nname: A\n" + String(repeating: "#", count: SnippetDetector.maximumSelectionLength)
        #expect(SnippetDetector.detect(selection: long) == nil)
        #expect(SnippetDetector.detect(selection: "#popclip\nname: A") != nil)
    }

    @Test(arguments: [
        ("export default {}", true),
        ("defineExtension({ actions: [] })", true),
        ("module.exports = {}", true),
        ("exports.actions = []", true),
        ("define({ actions: [] })", true),
        ("return popclip.input.text.toUpperCase();", false),
    ])
    func aModuleIsRecognisedByItsExports(_ source: String, _ isModule: Bool) {
        #expect(CodeBody(text: source, style: .slashes).looksLikeModule == isModule)
    }
}

/// FMT-4: a package has exactly one Config.
@Suite struct PackageInspectorTests {
    @Test(arguments: [
        ("Config.plist", PackageInspector.ConfigKind.data(.plist)),
        ("Config.json", .data(.json)),
        ("Config.yaml", .data(.yaml)),
        ("Config.js", .code(.javascript)),
        ("Config.ts", .code(.typescript)),
        ("Config.applescript", .code(.applescript)),
        ("Config", .code(nil)),
        ("Config.sh", .code(nil)),
    ])
    func theConfigsExtensionPicksTheParser(_ name: String, _ kind: PackageInspector.ConfigKind) throws {
        #expect(try PackageInspector.config(in: [name, "icon.png", "_Signature.plist"]).kind == kind)
    }

    @Test func thereIsExactlyOneConfig() {
        #expect(throws: PackageInspector.Failure.noConfig) { try PackageInspector.config(in: ["script.js"]) }
        #expect(throws: PackageInspector.Failure.severalConfigs(["Config.json", "Config.plist"])) {
            try PackageInspector.config(in: ["Config.plist", "Config.json"])
        }
    }

    @Test func theNameIsCaseSensitive() {
        #expect(throws: PackageInspector.Failure.noConfig) { try PackageInspector.config(in: ["config.json"]) }
        #expect(throws: PackageInspector.Failure.noConfig) { try PackageInspector.config(in: ["Configuration.json"]) }
    }

    @Test(arguments: [
        ("run.sh", true), ("lib/run.sh", true), ("./lib/../run.sh", true),
        ("../run.sh", false), ("lib/../../run.sh", false), ("/etc/hosts", false), ("~/run.sh", false), ("", false),
    ])
    func aPathMustStayInsideThePackage(_ path: String, _ contained: Bool) {
        #expect(PackageFiles.isContained(path) == contained)
    }

    @Test func aSymbolicLinkOutOfThePackageIsOutside() throws {
        let package = try Fixture.package(files: ["run.sh": "echo"])
        try FileManager.default.createSymbolicLink(
            at: package.root.appending(path: "escape"),
            withDestinationURL: URL(filePath: "/etc/hosts")
        )
        #expect(package.contains("run.sh"))
        #expect(!package.contains("escape"))
        #expect(!package.contains("missing.sh"))
    }
}

/// FMT-6.
@Suite struct ExtensionIdentifierTests {
    @Test(arguments: ["com.example.a", "a", "my-ext_2", "A1.b-c"])
    func wellFormedIdentifiersPass(_ identifier: String) {
        #expect(ExtensionIdentifier.problem(with: identifier) == nil)
    }

    @Test(arguments: [
        ("", ExtensionIdentifier.Problem.empty),
        ("-a", .separatorAtEnds),
        ("a.", .separatorAtEnds),
        ("a..b", .consecutiveSeparators),
        ("a-_b", .consecutiveSeparators),
        ("a b", .disallowedCharacter(" ")),
        ("a/b", .disallowedCharacter("/")),
    ])
    func malformedIdentifiersSayWhy(_ identifier: String, _ problem: ExtensionIdentifier.Problem) {
        #expect(ExtensionIdentifier.problem(with: identifier) == problem)
    }
}

/// The whole pipeline, from bytes on disk.
@Suite struct ExtensionLoaderTests {
    @Test func aPackageLoadsFromItsConfig() throws {
        let package = try Fixture.package(files: ["Config.yaml": "name: A\nidentifier: com.example.a\nurl: https://a.example/***"])
        let loaded = try ExtensionLoader.loadPackage(at: package.root)
        #expect(loaded.configFile == "Config.yaml")
        #expect(loaded.manifest.identifier == "com.example.a")
        #expect(!loaded.needsJavaScriptRuntime)
    }

    @Test func aPackageDiagnosticNamesItsFile() throws {
        let package = try Fixture.package(files: ["Config.json": #"{"name": "A", "url": "x", "flavour": 1}"#])
        let loaded = try ExtensionLoader.loadPackage(at: package.root)
        #expect(loaded.warnings.first?.path.hasPrefix("Config.json") == true)
    }

    @Test func aModuleWaitsForTheJavaScriptRuntime() throws {
        let package = try Fixture.package(files: ["Config.js": "// #popclip\n// name: A\nexport default { actions: [] };"])
        #expect(try ExtensionLoader.loadPackage(at: package.root).needsJavaScriptRuntime)
    }

    @Test func aSnippetLoads() throws {
        let loaded = try ExtensionLoader.loadSnippet("#popclip\nname: Shout\nkeyCombo: command b")
        #expect(loaded.manifest.actions[0].executor == .keyPress(KeyPressAction(steps: [.combo("command b")])))
        #expect(loaded.configFile == nil)
    }

    @Test func aShellSnippetLoads() throws {
        let loaded = try ExtensionLoader.loadSnippet("#!/bin/zsh\n# #popclip\n# name: Up\ntr a-z A-Z")
        guard case .shellScript(let shell) = loaded.manifest.actions[0].executor else {
            Issue.record("not a shell script")
            return
        }
        #expect(shell.interpreter == "/bin/zsh")
    }

    @Test func textThatIsNotASnippetIsRefused() {
        #expect(throws: ManifestLoadFailure.self) { try ExtensionLoader.loadSnippet("hello") }
    }
}
