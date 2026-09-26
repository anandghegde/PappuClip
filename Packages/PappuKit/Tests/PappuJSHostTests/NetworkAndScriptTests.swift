import Foundation
import PappuCore
import PappuJSBridge
@testable import PappuJSHost
import Testing

/// JS-8 from the helper's side: `XMLHttpRequest` is a host call, and axios's adapter works through it.
/// The app's answers are written out here; what the app decides is `NetworkHostCallsTests`'.
@Suite struct XMLHttpRequestTests {
    typealias Harness = JSHostAPITests.Harness

    struct Arguments: Decodable, Equatable {
        var method: String
        var url: String
        var headers: [[String]]
        var body: String?
        var timeout: Double
    }

    static func response(_ body: String, status: Int = 200, type: String = "application/json") -> JSHostAnswer {
        let answer: [String: Any] = [
            "status": status,
            "statusText": status == 200 ? "no error" : "not found",
            "headers": ["content-type": type, "x-test": "yes"],
            "url": "https://api.example.com/v1/items",
            "body": Data(body.utf8).base64EncodedString(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: answer)
        return .value(String(decoding: data, as: UTF8.self))
    }

    static func arguments(_ call: JSHostCall) throws -> Arguments {
        try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
    }

    @Test func axiosGetsThroughTheShim() async throws {
        let tests = Harness { call in
            call.method == "httpRequest" ? Self.response(#"{"items":[1,2]}"#) : .done
        }
        let script = """
        const axios = require('axios');
        const r = await axios.get('https://api.example.com/v1/items', { params: { q: 'a b' }, headers: { 'X-Key': 'k' } });
        return JSON.stringify([r.status, r.data.items, r.headers['x-test']]);
        """
        #expect(await tests.run(script) == .returned(#"[200,[1,2],"yes"]"#))
        let call = try #require(tests.app.calls.first)
        #expect(call.method == "httpRequest")
        let sent = try Self.arguments(call)
        #expect(sent.method == "GET")
        #expect(sent.url == "https://api.example.com/v1/items?q=a+b")
        #expect(sent.headers.contains(["X-Key", "k"]))
        #expect(sent.body == nil)
    }

    @Test func axiosPostsItsBody() async throws {
        let tests = Harness { _ in Self.response("{}") }
        let script = "const r = await require('axios').post('https://api.example.com/v1', { text: 'hi' }); return String(r.status)"
        #expect(await tests.run(script) == .returned("200"))
        let sent = try Self.arguments(try #require(tests.app.calls.first))
        #expect(sent.method == "POST")
        #expect(sent.body.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } == #"{"text":"hi"}"#)
    }

    /// A refusal — an undeclared host — is a network error to the script, as a browser has it.
    @Test func aRefusedRequestIsANetworkError() async {
        let tests = Harness { _ in .refused("httpRequest may only reach the hosts the extension declares in networkHosts.") }
        let script = "try { await require('axios').get('https://evil.test/'); return 'sent' } catch (e) { return e.message }"
        #expect(await tests.run(script) == .returned("Network Error"))
    }

    @Test func aTimeoutIsATimeout() async {
        let tests = Harness { _ in .value(#"{"timedOut":true}"#) }
        let script = "try { await require('axios').get('https://api.example.com/', { timeout: 50 }); return 'sent' } catch (e) { return e.code }"
        #expect(await tests.run(script) == .returned("ECONNABORTED"))
        let sent = try? Self.arguments(tests.app.calls[0])
        #expect(sent?.timeout == 50)
    }

    @Test func theObjectIsTheBrowsersShape() async {
        let tests = Harness { _ in Self.response("hello", type: "text/plain") }
        let script = """
        const xhr = new XMLHttpRequest();
        const states = [];
        xhr.onreadystatechange = () => states.push(xhr.readyState);
        const done = new Promise((resolve) => xhr.addEventListener('loadend', resolve));
        xhr.open('GET', 'https://api.example.com/v1/items');
        xhr.responseType = 'arraybuffer';
        xhr.send();
        await done;
        return JSON.stringify([states, xhr.status, Buffer.from(xhr.response).toString(), xhr.getResponseHeader('Content-Type'),
          xhr.getAllResponseHeaders(), xhr.responseURL, 'onloadend' in xhr, XMLHttpRequest.DONE]);
        """
        let expected = #"[[1,2,3,4],200,"hello","text/plain","content-type: text/plain\r\nx-test: yes\r\n","https://api.example.com/v1/items",true,4]"#
        #expect(await tests.run(script) == .returned(expected))
    }

    @Test func aSynchronousRequestIsRefused() async {
        let script = "try { new XMLHttpRequest().open('GET', 'https://a.test/', false); return 'open' } catch (e) { return e.message }"
        #expect(await Harness().run(script) == .returned("PappuClip makes asynchronous requests only."))
    }
}

/// JS-5 from the helper's side: what each script method sends and how its answer settles.
@Suite struct ExternalScriptTests {
    typealias Harness = JSHostAPITests.Harness

    static func shell(status: Int, stdout: String, stderr: String = "", reason: String = "exit") -> JSHostAnswer {
        let data = try! JSONSerialization.data(withJSONObject: ["status": status, "stdout": stdout, "stderr": stderr, "terminationReason": reason])
        return .value(String(decoding: data, as: UTF8.self))
    }

    static func arguments(_ call: JSHostCall) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aShellScriptResolvesToItsOutput() async {
        let tests = Harness { _ in Self.shell(status: 0, stdout: "HELLO\n") }
        let script = "return await popclip.runShellScript('tr a-z A-Z', { stdin: 'hello', env: { MODE: 1 } })"
        #expect(await tests.run(script) == .returned("HELLO"))
        #expect(tests.app.calls.map(\.method) == ["runShellScript"])
        let sent = Self.arguments(tests.app.calls[0])
        #expect(sent["script"] as? String == "tr a-z A-Z")
        #expect(sent["stdin"] as? String == "hello")
        #expect(sent["shellMode"] as? String == "login")
        #expect(sent["env"] as? [String: String] == ["MODE": "1"])
    }

    /// A failing script rejects with everything it said, so the extension may read why.
    @Test func aNonZeroExitRejectsWithItsStatusAndOutput() async throws {
        let tests = Harness { _ in Self.shell(status: 3, stdout: "partial\n", stderr: "no such file\n") }
        let script = """
        try { await popclip.runShellScriptFile('bin/tool.sh'); return 'ok' }
        catch (e) { return JSON.stringify([e.message, e.status, e.stdout, e.stderr, e.terminationReason]) }
        """
        let expected = #"["The shell script exited with status 3: no such file",3,"partial\n","no such file\n","exit"]"#
        #expect(await tests.run(script) == .returned(expected))
        #expect(Self.arguments(try #require(tests.app.calls.first))["file"] as? String == "bin/tool.sh")
    }

    @Test func aSignalRejectsToo() async {
        let tests = Harness { _ in Self.shell(status: 9, stdout: "", reason: "uncaughtSignal") }
        let script = "try { await popclip.runShellScript('sleep 9'); return 'ok' } catch (e) { return e.terminationReason + ' ' + e.status }"
        #expect(await tests.run(script) == .returned("uncaughtSignal 9"))
    }

    /// `$` quotes every value as one word, so the text is never read as shell syntax.
    @Test func theShellTagQuotesWhatItIsGiven() async {
        let tests = Harness { _ in Self.shell(status: 0, stdout: "done\n") }
        let script = "const text = \"it's $(rm -rf ~)\"; return await $`echo ${text} ${['a b', 'c']} | wc -c`"
        #expect(await tests.run(script) == .returned("done"))
        let sent = Self.arguments(tests.app.calls[0])
        #expect(sent["script"] as? String == "set -euo pipefail\necho 'it'\\''s $(rm -rf ~)' 'a b' 'c' | wc -c")
        #expect(sent["interpreter"] as? String == "/bin/zsh")
    }

    @Test func appleScriptsAndShortcutsSendWhatTheyAreGiven() async {
        let tests = Harness { call in call.method == "runShortcut" ? .value(#""made""#) : .value(#""told""#) }
        let script = """
        const a = await popclip.runAppleScript('return 1');
        const b = await popclip.runAppleScriptFile('run.applescript', { handler: 'go', params: { first: 'x', second: 2 } });
        const c = await popclip.runShortcut('Make', { input: 'text' });
        return [a, b, c].join(' ');
        """
        let reply = await tests.run(script)
        #expect(reply == .returned("told told made"), "\(reply)")
        #expect(tests.app.calls.map(\.method) == ["runAppleScript", "runAppleScript", "runShortcut"])
        let file = Self.arguments(tests.app.calls[1])
        #expect(file["file"] as? String == "run.applescript")
        #expect(file["handler"] as? String == "go")
        #expect(file["params"] as? [String] == ["x", "2"])
        #expect(Self.arguments(tests.app.calls[2])["input"] as? String == "text")
    }

    /// The app's refusal — no grant, no entitlement — is the script's rejection.
    @Test func aRefusalRejects() async {
        let tests = Harness { _ in .refused("runShellScript needs the script permission, which this extension does not have.") }
        let script = "try { await popclip.runShellScript('true'); return 'ran' } catch (e) { return e.message }"
        #expect(await tests.run(script) == .returned("runShellScript needs the script permission, which this extension does not have."))
    }
}

/// EXM-5f: the reachable-method scan.
@Suite struct CodeScannerTests {
    static func scan(_ text: String, name: String = "main.js") -> JSScanReport {
        CodeScanner.shared.scan(JSScan(sources: [JSScan.Source(name: name, text: text)]))
    }

    @Test func theListIsCodeScans() {
        #expect(Set(CodeScanner.sensitive) == CodeScan.sensitiveMethods)
    }

    @Test func namedMethodsAreFound() {
        let report = Self.scan("popclip.pasteText('x'); await popclip.pressKey('command b'); pappuclip['runShellScript']('ls'); await $`ls`")
        #expect(report == JSScanReport(methods: ["$", "pressKey", "runShellScript"], unbounded: []))
    }

    @Test func theNetworkIsFoundThroughItsDoors() {
        #expect(Self.scan("const x = new XMLHttpRequest()").methods == ["XMLHttpRequest"])
        #expect(Self.scan("const axios = require('axios')").methods == ["XMLHttpRequest"])
        #expect(Self.scan("import axios from 'axios'\nexport default 1").methods == ["XMLHttpRequest"])
        #expect(Self.scan("const name = 'ax' + 'ios'; require(name)").methods == ["XMLHttpRequest"])
        #expect(Self.scan("const yaml = require('js-yaml')").methods == [])
    }

    /// Names that are not references are not calls: a key, a binding, a label, a `typeof`.
    @Test func namesThatAreNotReferencesAreNotCounted() {
        let report = Self.scan("const o = { pressKey: 1, share() {} }; function f(share) {} ; o.pressKey; typeof popclip; x instanceof Function")
        #expect(report == JSScanReport(methods: [], unbounded: []))
    }

    @Test func whatCannotBeBoundedSaysWhy() {
        #expect(Self.scan("const p = popclip; p.pressKey('a')").unbounded == ["aliased-popclip"])
        #expect(Self.scan("run(popclip)").unbounded == ["aliased-popclip"])
        #expect(Self.scan("const { pressKey } = popclip").unbounded == ["aliased-popclip"])
        #expect(Self.scan("popclip[name]()").unbounded == ["computed-access"])
        #expect(Self.scan("globalThis.popclip.pressKey()").unbounded == ["aliased-popclip"])
        #expect(Self.scan("globalThis[k]").unbounded == ["global-object"])
        #expect(Self.scan("eval('1')").unbounded == ["eval"])
        #expect(Self.scan("new Function('return 1')").unbounded == ["function-constructor"])
        #expect(Self.scan("(() => 1).constructor('return 1')()").unbounded == ["function-constructor"])
        #expect(Self.scan("with (o) { x }").unbounded == ["with"])
        #expect(Self.scan("this is not JavaScript (").unbounded == ["unreadable"])
    }

    @Test func typeScriptIsReadWithoutItsTypes() {
        let report = Self.scan("const n: number = 1\nexport async function go(): Promise<void> { await popclip.share('x', []) }", name: "main.ts")
        #expect(report == JSScanReport(methods: ["share"], unbounded: []))
    }

    @Test func everyFileCounts() {
        let report = CodeScanner.shared.scan(JSScan(sources: [
            JSScan.Source(name: "a.js", text: "popclip.pressKey('a')"),
            JSScan.Source(name: "b.js", text: "eval(x)"),
        ]))
        #expect(report == JSScanReport(methods: ["pressKey"], unbounded: ["eval"]))
    }
}
