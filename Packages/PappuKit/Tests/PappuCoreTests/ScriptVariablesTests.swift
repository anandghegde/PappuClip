import Foundation
import PappuCore
import Testing

/// §8.7: the table a script is given, read as an environment and as placeholders.
@Suite struct ScriptVariablesTests {
    private let variables = ScriptVariables(.init(
        text: "narrowed",
        fullText: "the whole selection",
        urls: ["https://a.example", "https://b.example"],
        modifiers: [.shift, .command],
        bundleIdentifier: "com.apple.Safari",
        appName: "Safari",
        browserURL: "https://page.example",
        extensionIdentifier: "com.example.ext",
        actionIdentifier: "go",
        options: ["apiKey": "secret", "api-mode": "1"]
    ))

    @Test func everyValueIsSetUnderBothPrefixes() {
        let environment = variables.environment
        for prefix in ["POPCLIP_", "PAPPUCLIP_"] {
            #expect(environment[prefix + "TEXT"] == "narrowed")
            #expect(environment[prefix + "FULL_TEXT"] == "the whole selection")
            #expect(environment[prefix + "URLS"] == "https://a.example\nhttps://b.example")
            #expect(environment[prefix + "BUNDLE_IDENTIFIER"] == "com.apple.Safari")
            #expect(environment[prefix + "OPTION_APIKEY"] == "secret")
            #expect(environment[prefix + "OPTION_API_MODE"] == "1")
        }
    }

    /// §8.7's sums: shift 131072 plus command 1048576.
    @Test func modifierFlagsAreSummed() {
        #expect(variables.values["MODIFIER_FLAGS"] == "1179648")
    }

    /// "Missing values are empty", not absent.
    @Test func aMissingValueIsEmpty() {
        #expect(variables.environment["POPCLIP_BROWSER_TITLE"] == "")
        #expect(variables.environment["POPCLIP_HTML"] == "")
        #expect(variables.environment["POPCLIP_MARKDOWN"] == "")
    }

    @Test func theTextIsAlsoGivenEncoded() {
        let encoded = ScriptVariables(.init(text: "a b&c/é"))
        #expect(encoded.values["URLENCODED_TEXT"] == "a%20b%26c%2F%C3%A9")
    }

    @Test func stdinNamesAVariable() {
        #expect(variables.value(named: "text") == "narrowed")
        #expect(variables.value(named: "full text") == "the whole selection")
        #expect(variables.value(named: "POPCLIP_FULL_TEXT") == "the whole selection")
        #expect(variables.value(named: "nonsense") == nil)
    }

    @Test func placeholdersAreReadEitherWay() {
        #expect(variables.value(forPlaceholder: "popclip text") == "narrowed")
        #expect(variables.value(forPlaceholder: "pappuclip full text") == "the whole selection")
        #expect(variables.value(forPlaceholder: "popclip app name") == "Safari")
        #expect(variables.value(forPlaceholder: "popclip option apiKey") == "secret")
        #expect(variables.value(forPlaceholder: "popclip option apikey") == "secret")
        #expect(variables.value(forPlaceholder: "popclip option unset") == "")
        #expect(variables.value(forPlaceholder: "popclip no such thing") == nil)
        #expect(variables.value(forPlaceholder: "1, 2") == nil)
    }

    /// A quote in the selection cannot end the string it was put in.
    @Test func substitutedTextIsEscapedForAStringLiteral() {
        let quoted = ScriptVariables(.init(text: #"say "hi" \ bye"#))
        let script = quoted.substitutingPlaceholders(in: #"set t to "{popclip text}""#)
        #expect(script == #"set t to "say \"hi\" \\ bye""#)
    }

    /// Braces are AppleScript's too. Only §8.7's names are replaced, including inside a record.
    @Test func otherBracesAreLeftAlone() {
        let script = variables.substitutingPlaceholders(in: #"set r to {1, 2, "{popclip text}"} & {x:"{"#)
        #expect(script == #"set r to {1, 2, "narrowed"} & {x:"{"#)
    }
}

/// §8.4: which program runs a shell script, and how its exit reads.
@Suite struct ShellInvocationTests {
    private let script = "/ext/Package/run.py"

    private func plan(
        interpreter: String? = nil,
        mode: ShellScriptAction.Mode? = nil,
        inline: String? = nil,
        shell: String? = "/bin/zsh",
        executables: Set<String> = []
    ) throws(ShellInvocation.Refusal) -> ShellInvocation {
        try ShellInvocation.plan(
            ShellScriptAction(source: inline.map { .inline($0) } ?? .file("run.py"), interpreter: interpreter, mode: mode),
            script: script,
            inlineSource: inline,
            userShell: shell,
            isExecutable: { executables.contains($0) }
        )
    }

    /// The default: a login shell, so a bare interpreter name is found on the user's own PATH, and the
    /// command handed over as arguments rather than as source.
    @Test func loginIsTheDefault() throws {
        let invocation = try plan(interpreter: "python3")
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments == ["-l", "-c", "exec \"$@\"", "pappuclip", "python3", script])
    }

    @Test func nonloginSkipsTheLoginFiles() throws {
        let invocation = try plan(interpreter: "ruby", mode: .nonlogin, shell: "/bin/bash")
        #expect(invocation.executable == "/bin/bash")
        #expect(invocation.arguments == ["-c", "exec \"$@\"", "pappuclip", "ruby", script])
    }

    @Test func noneStartsTheProgramDirectly() throws {
        let invocation = try plan(interpreter: "python3", mode: ShellScriptAction.Mode.none, executables: ["/opt/homebrew/bin/python3"])
        #expect(invocation.executable == "/opt/homebrew/bin/python3")
        #expect(invocation.arguments == [script])
    }

    @Test func noneWithAnInterpreterNobodyHasRefuses() {
        #expect(throws: ShellInvocation.Refusal.interpreterNotFound("python9")) {
            try plan(interpreter: "python9", mode: ShellScriptAction.Mode.none)
        }
    }

    @Test func anInterpreterMayCarryArguments() throws {
        let invocation = try plan(interpreter: "/usr/bin/env python3", mode: ShellScriptAction.Mode.none)
        #expect(invocation.executable == "/usr/bin/env")
        #expect(invocation.arguments == ["python3", script])
    }

    /// Accepted at load because it has `#!` and the executable bit.
    @Test func anExecutableFileRunsAsItself() throws {
        let invocation = try plan(mode: ShellScriptAction.Mode.none)
        #expect(invocation.executable == script)
        #expect(invocation.arguments.isEmpty)
    }

    @Test func anInlineScriptWithNoInterpreterIsSh() throws {
        #expect(try plan(inline: "echo hi", shell: nil).arguments.suffix(2) == ["/bin/sh", script])
        #expect(try plan(inline: "#!/usr/bin/perl\nprint 1").arguments.last == script)
    }

    /// A shell that does not read `exec "$@"` the POSIX way is not used.
    @Test func anUnusualShellIsReplaced() throws {
        #expect(try plan(interpreter: "sh", shell: "/opt/homebrew/bin/fish").executable == "/bin/zsh")
        #expect(try plan(interpreter: "sh", shell: "zsh").executable == "/bin/zsh")
        #expect(try plan(interpreter: "sh", shell: "/opt/homebrew/bin/bash").executable == "/opt/homebrew/bin/bash")
    }

    @Test func exitCodesReadAsTheSpecSays() {
        #expect(ScriptExit(status: 0, signalled: false) == .succeeded)
        #expect(ScriptExit(status: 2, signalled: false) == .needsSettings)
        #expect(ScriptExit(status: 1, signalled: false) == .failed)
        #expect(ScriptExit(status: 2, signalled: true) == .failed)
    }
}
