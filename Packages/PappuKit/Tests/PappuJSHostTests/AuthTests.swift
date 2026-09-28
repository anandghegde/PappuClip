import Foundation
import PappuCore
import PappuJSBridge
@testable import PappuJSHost
import Testing

/// §8.10 from the helper's side: `auth(info, flow)` runs with the app's `info`, `flow` is an `authFlow`
/// host call, and the secret reaches the app as an `authSecret` call rather than as the reply.
@Suite struct AuthFunctionTests {
    typealias Harness = JSHostAPITests.Harness

    static let info = JSAuthInfo(username: "ann", password: "pw", redirect: "http://127.0.0.1:5000/callback", name: "Svc", identifier: "com.example.svc")

    func auth(_ tests: Harness, _ module: String) async -> JSHostReply {
        _ = await tests.ask(.load(JSLoad(extensionName: "a", generation: "1", files: ["Config.js": module])))
        return await tests.ask(.invoke(JSInvoke(
            invocation: 9, extensionName: "a", generation: "1", entry: .file("Config.js"),
            input: JSInput(text: "", matchedText: ""), auth: Self.info
        )))
    }

    @Test func authRunsWithInfoAndFlowAndHandsTheSecretToTheApp() async throws {
        let tests = Harness { call in
            call.method == "authFlow" ? .value(#"{"code":"abc"}"#) : .done
        }
        let module = """
        exports.auth = async (info, flow) => {
          const { code } = await flow('https://svc.example/authorize', { client_id: 'x', redirect_uri: info.redirect, n: 3 }, ['code']);
          return info.username + ':' + info.password + ':' + info.identifier + ':' + code;
        };
        exports.action = () => 'unused';
        """
        #expect(await auth(tests, module) == .returned(nil))
        #expect(tests.app.calls.map(\.method) == ["authFlow", "authSecret"])
        let flow = try JSONSerialization.jsonObject(with: Data(tests.app.calls[0].arguments.utf8)) as? [String: Any]
        #expect(flow?["url"] as? String == "https://svc.example/authorize")
        #expect(flow?["params"] as? [String: String] == ["client_id": "x", "redirect_uri": "http://127.0.0.1:5000/callback", "n": "3"])
        #expect(flow?["expect"] as? [String] == ["code"])
        #expect(tests.app.calls[1].arguments == #"{"secret":"ann:pw:com.example.svc:abc"}"#)
        #expect(tests.app.calls.allSatisfy { $0.invocation == 9 })
    }

    @Test func aModuleWithoutAuthFails() async {
        let tests = Harness()
        #expect(await auth(tests, "exports.action = () => 'x'") == .threw("The extension has no auth function."))
        #expect(tests.app.calls.isEmpty)
    }

    @Test func noSecretIsAFailure() async {
        let tests = Harness()
        #expect(await auth(tests, "exports.auth = async () => ''") == .threw("The auth function returned no secret."))
        #expect(tests.app.calls.isEmpty)
    }

    /// A timed-out or cancelled flow is a refusal the function sees as a rejected promise.
    @Test func aFailedFlowRejectsInTheFunction() async {
        let tests = Harness { _ in .refused("The sign-in timed out.") }
        #expect(await auth(tests, "exports.auth = async (i, flow) => { await flow('https://x.example', {}, ['code']); return 's' }")
            == .threw("The sign-in timed out."))
        #expect(tests.app.calls.map(\.method) == ["authFlow"])
    }
}
