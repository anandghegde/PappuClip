import Foundation
import PappuCore
import PappuRuntime
import Testing

/// §8.4 Shell Script and §8.7, as the app runs them: real processes, because the environment, the
/// pipes and the signals are the thing under test.
@Suite struct SystemShellScriptRunnerTests {
    private static let variables = ScriptVariables(ScriptVariables.Inputs(
        text: "hello world",
        fullText: "say hello world",
        appName: "Editor",
        options: ["apiKey": "secret"]
    ))

    private static func run(
        _ action: ShellScriptAction,
        directory: URL? = nil,
        variables: ScriptVariables = variables
    ) async throws -> ScriptResult {
        let started = try #require(await SystemShellScriptRunner().start(
            ShellScriptJob(action: action, directory: directory, variables: variables)
        ))
        return await started.result()
    }

    private static func package() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("pappu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    /// Both prefixes, and one line break less at the end.
    @Test func bothPrefixesAreSetAndTheLastLineBreakGoes() async throws {
        let result = try await Self.run(ShellScriptAction(
            source: .inline(#"echo "$POPCLIP_TEXT|$PAPPUCLIP_FULL_TEXT|$POPCLIP_APP_NAME|$PAPPUCLIP_OPTION_APIKEY""#),
            mode: .nonlogin
        ))
        #expect(result == .returned("hello world|say hello world|Editor|secret"))
    }

    /// §8.7: a missing value is an empty variable, not an unset one.
    @Test func aMissingValueIsEmptyNotUnset() async throws {
        let result = try await Self.run(ShellScriptAction(
            source: .inline(#"[ "${POPCLIP_BROWSER_URL+set}" = set ] && echo set"#),
            mode: .nonlogin
        ))
        #expect(result == .returned("set"))
    }

    @Test func standardInputIsTheNamedValue() async throws {
        let result = try await Self.run(ShellScriptAction(source: .inline("tr a-z A-Z"), stdin: "text", mode: .nonlogin))
        #expect(result == .returned("HELLO WORLD"))
    }

    /// The app's own environment is not the script's.
    @Test func theEnvironmentIsSmall() async throws {
        let result = try await Self.run(ShellScriptAction(
            source: .inline(#"env | grep -v -e '^POPCLIP_' -e '^PAPPUCLIP_' | cut -d= -f1 | grep -v '^_$' | grep -v '^PWD$' | grep -v '^SHLVL$' | sort | tr '\n' ' '"#),
            mode: .nonlogin
        ))
        #expect(result == .returned("HOME LANG LOGNAME PATH SHELL TMPDIR USER "))
    }

    /// An interpreter by bare name, found by the login shell's PATH, and a file run from its package.
    @Test func aFileRunsInItsPackageUnderItsInterpreter() async throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        try "import os, sys\nprint(os.getcwd() + '|' + sys.stdin.read().upper())\n"
            .write(to: package.appendingPathComponent("shout.py"), atomically: true, encoding: .utf8)
        let result = try await Self.run(
            ShellScriptAction(source: .file("shout.py"), interpreter: "python3", stdin: "text"),
            directory: package
        )
        // `realpath`, not `resolvingSymlinksInPath`, which turns /private/var back into /var.
        let real = try #require(realpath(package.path, nil))
        defer { free(real) }
        #expect(result == .returned(String(cString: real) + "|HELLO WORLD"))
    }

    /// **Done when: exit code 2 opens settings.**
    @Test func exitTwoAsksForSettingsAndOtherFailuresFail() async throws {
        #expect(try await Self.run(ShellScriptAction(source: .inline("exit 2"), mode: .nonlogin)) == .needsSettings)
        #expect(try await Self.run(ShellScriptAction(source: .inline("exit 1"), mode: .nonlogin)) == .failed)
        #expect(try await Self.run(ShellScriptAction(source: .inline("true"), mode: .none)) == .returned(nil))
    }

    @Test func aFileOutsideItsPackageIsNotStarted() async throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let started = await SystemShellScriptRunner().start(ShellScriptJob(
            action: ShellScriptAction(source: .file("../../../../bin/sh")),
            directory: package,
            variables: Self.variables
        ))
        #expect(started == nil)
    }

    @Test func anInterpreterThatCannotBeFoundIsNotStarted() async throws {
        let started = await SystemShellScriptRunner().start(ShellScriptJob(
            action: ShellScriptAction(source: .inline("x"), interpreter: "no-such-interpreter-pappu", mode: ShellScriptAction.Mode.none),
            directory: nil,
            variables: Self.variables
        ))
        #expect(started == nil)
    }

    /// RUN-3d: a script that hangs is stopped, and says it was — a script is ours, so `stopped`.
    @Test func aHungScriptIsStopped() async throws {
        let started = try #require(await SystemShellScriptRunner().start(ShellScriptJob(
            action: ShellScriptAction(source: .inline("sleep 60"), mode: .nonlogin),
            directory: nil,
            variables: Self.variables
        )))
        #expect(started.ownership == .owned)
        let clock = ContinuousClock()
        let began = clock.now
        #expect(await started.cancel() == .stopped)
        #expect(await started.result() == .stopped)
        #expect(clock.now - began < .seconds(10))
    }
}
