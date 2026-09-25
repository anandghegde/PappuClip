import Foundation
import PappuCore
import Testing

/// SEC-7a, EXM-5b: an extension's capabilities are worked out from what its actions are, and sorted
/// into safety spec §S4's two levels.
@Suite struct CapabilityAnalyzerTests {
    static func manifest(
        _ executors: [ActionExecutor],
        entitlements: [Entitlement] = [],
        networkHosts: [String] = [],
        module: ModuleReference? = nil
    ) -> ExtensionManifest {
        ExtensionManifest(
            name: "Ext",
            identifier: "com.example.ext",
            entitlements: entitlements,
            module: module,
            networkHosts: networkHosts,
            actions: executors.enumerated().map { index, executor in
                ActionManifest(title: LocalizedText("A\(index)"), identifier: "a\(index)", executor: executor)
            }
        )
    }

    // MARK: Listed

    @Test func aFixedHostURLNamesTheHostAndSaysTheTextGoesThere() {
        let set = CapabilityAnalyzer.effective(Self.manifest([.url(URLAction(template: "https://www.Example.com/search?q=***"))]))
        #expect(set.listed == [.opensWebPage(host: "www.example.com", withText: true)])
        #expect(set.isListedOnly)
    }

    @Test func aURLWithoutTheTextSaysSo() {
        #expect(CapabilityAnalyzer.destination(of: "https://example.com/") == .opensWebPage(host: "example.com", withText: false))
    }

    /// The corpus puts hosts in options (`https://{popclip option site}/…`); that host is the user's.
    @Test func anOptionDerivedHostIsConfigured() {
        #expect(CapabilityAnalyzer.destination(of: "https://{popclip option site}/q={popclip text}") == .opensConfiguredURL(withText: true))
        #expect(CapabilityAnalyzer.destination(of: "{popclip option url}{popclip text}") == .opensConfiguredURL(withText: true))
        #expect(CapabilityAnalyzer.destination(of: "https://example.com/{popclip option path}") == .opensWebPage(host: "example.com", withText: false))
    }

    /// A known destination that is an app rather than a website (SEC-7a).
    @Test func anAppSchemeIsThatApp() {
        #expect(CapabilityAnalyzer.destination(of: "things:///add?title={popclip text}") == .opensAppLink(scheme: "things", withText: true))
    }

    @Test func keyPressesAreShownAsTheMenusWriteThem() {
        let press = KeyPressAction(steps: [.combo("command a"), .wait(milliseconds: 100), .combo("option shift return")])
        let set = CapabilityAnalyzer.effective(Self.manifest([.keyPress(press)]))
        #expect(set.listed == [.pressesKeys(["⌘A", "⌥⇧↩"])])
    }

    @Test func servicesAndShortcutsAreNamed() {
        let set = CapabilityAnalyzer.effective(Self.manifest([
            .service(ServiceAction(name: "Make Sticky")),
            .shortcut(ShortcutAction(name: "Add to Journal")),
        ]))
        #expect(set.listed == [.runsService("Make Sticky"), .runsShortcut("Add to Journal")])
        #expect(set.gated.isEmpty)
    }

    @Test func aRepeatedCapabilityIsListedOnce() {
        let url = ActionExecutor.url(URLAction(template: "https://example.com/?q=***"))
        #expect(CapabilityAnalyzer.effective(Self.manifest([url, url])).listed.count == 1)
    }

    @Test func dynamicAndBoundedNetworkAreListed() {
        let set = CapabilityAnalyzer.effective(Self.manifest([], entitlements: [.dynamic, .network], networkHosts: ["api.example.com"]))
        #expect(set.listed == [.runsOnEveryAppearance, .sendsData(toHosts: ["api.example.com"])])
        #expect(set.gated.isEmpty)
    }

    // MARK: Gated

    @Test func shellAndAppleScriptAreGatedAsScript() {
        let shell = ActionExecutor.shellScript(ShellScriptAction(source: .inline("say hi")))
        let apple = ActionExecutor.appleScript(AppleScriptAction(source: .inline("beep")))
        #expect(CapabilityAnalyzer.effective(Self.manifest([shell])).gated == [.script])
        #expect(CapabilityAnalyzer.effective(Self.manifest([apple])).gated == [.script])
    }

    @Test func networkWithoutHostsIsGated() {
        #expect(CapabilityAnalyzer.effective(Self.manifest([], entitlements: [.network])).gated == [.network])
        #expect(CapabilityAnalyzer.effective(Self.manifest([], entitlements: [.script])).gated == [.script])
    }

    /// SEC-7c: JavaScript this build cannot scan is disclosed as the broader thing, and with it the host
    /// methods that reach past the text (SEC-7b), which it does not need to run.
    @Test func unscannedJavaScriptIsUnbounded() {
        let js = ActionExecutor.javaScript(JavaScriptAction(source: .inline("return 1")))
        let manifest = Self.manifest([js])
        #expect(CapabilityAnalyzer.effective(manifest).gated == [.syntheticInput, .unboundedCode])
        #expect(CapabilityAnalyzer.gates(of: manifest.actions[0], in: manifest) == [.unboundedCode])
        let module = Self.manifest([], module: .file("main.js"))
        #expect(CapabilityAnalyzer.effective(module).gated == [.syntheticInput, .unboundedCode])
        #expect(CapabilityAnalyzer.effective(Self.manifest([], module: .detection(false))).gated.isEmpty)
    }

    /// SEC-7d: each action answers for its own type, so an extension's URL action never needs the grant
    /// its shell action does, and the shell action always does.
    @Test func eachActionNeedsOnlyItsOwnGates() {
        let manifest = Self.manifest([
            .url(URLAction(template: "https://example.com/***")),
            .shellScript(ShellScriptAction(source: .inline("true"))),
        ])
        #expect(CapabilityAnalyzer.gates(of: manifest.actions[0], in: manifest).isEmpty)
        #expect(CapabilityAnalyzer.gates(of: manifest.actions[1], in: manifest) == [.script])
    }

    // MARK: Known destinations

    @Test func appleScriptTellTargetsAreKnownDestinations() {
        let source = """
        tell application "Safari" to activate
        tell app "Notes"
        end tell
        TELL APPLICATION id "com.apple.mail"
        """
        #expect(CapabilityAnalyzer.tellTargets(in: source) == ["Safari", "Notes", "com.apple.mail"])
    }

    @Test func aScriptFileIsReadForItsTargets() {
        let manifest = Self.manifest([.appleScript(AppleScriptAction(source: .file("run.applescript")))])
        let set = CapabilityAnalyzer.effective(manifest) { path in
            path == "run.applescript" ? #"tell application "Things3" to activate"# : nil
        }
        #expect(set.controlledApps == ["Things3"])
    }

    @Test func aFileOutsideThePackageIsNotRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = folder.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"tell application "Outside""#.write(to: folder.appendingPathComponent("x.applescript"), atomically: true, encoding: .utf8)
        try #"tell application "Inside""#.write(to: package.appendingPathComponent("y.applescript"), atomically: true, encoding: .utf8)
        let manifest = Self.manifest([
            .appleScript(AppleScriptAction(source: .file("../x.applescript"))),
            .appleScript(AppleScriptAction(source: .file("y.applescript"))),
        ])
        #expect(CapabilityAnalyzer.effective(manifest, directory: package).controlledApps == ["Inside"])
    }

    @Test func gatedKeysAreTheStoresFormat() {
        #expect(GatedCapability.allCases.map(\.rawValue) == ["script", "network", "synthetic-input", "unbounded-code"])
    }
}
