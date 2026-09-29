import Foundation
import PappuCore
import PappuJSBridge
import PappuJSHost
import PappuRuntime
import Synchronization

/// DEV-2: the app's side of a script's host calls when there is no app (architecture §10.8).
///
/// **The same refusals, none of the effects.** A call is checked as `HostAPIDispatcher` checks it —
/// a method nobody has is refused, and a gated method is refused without its grant in the same words —
/// and then, instead of reaching a destination, the clipboard or the system, it is written down. What
/// a script asked for is what `pappuclip run` prints and what a test asserts. The one thing that is
/// kept is a clipboard of its own, so a script that copies and then reads sees what it copied.
///
/// **What it will not do.** It sends no request (`httpRequest`), runs no shell script, AppleScript or
/// Shortcut, and shows no panel: each of those is refused after the grant check, with a message that
/// says so, so that a script's failure here is never mistaken for the app's rules.
public final class HeadlessHost: Sendable {
    /// One call a script made, and what it was told.
    public struct Call: Sendable, Equatable {
        public var method: String
        /// The call's arguments as the script sent them, as JSON.
        public var arguments: String
        public var answer: JSHostAnswer

        public init(method: String, arguments: String, answer: JSHostAnswer) {
            self.method = method
            self.arguments = arguments
            self.answer = answer
        }

        /// The call reached what it asked for, as far as a headless run can: it was not refused.
        public var wasServed: Bool {
            if case .refused = answer { return false }
            return true
        }
    }

    /// The methods served elsewhere in the app, by `HostCallHandling` groups, and the grant each needs
    /// before anything else is looked at. `httpRequest` needs `network` only when the extension has no
    /// `networkHosts`; a headless run grants it with `--allow network` or not at all.
    static let groupGates: [String: GatedCapability?] = [
        NetworkHostCalls.method: .network,
        ScriptHostCalls.shell: .script,
        ScriptHostCalls.appleScript: .script,
        ScriptHostCalls.shortcut: .script,
        PromptHostCalls.method: nil,
    ]

    /// What a headless run does not do, in the words a script is refused with.
    static func notServed(_ method: String) -> JSHostAnswer {
        .refused("\(method) is not available in a headless run.")
    }

    private let gates: Set<GatedCapability>
    private let calls = Mutex<[Call]>([])
    private let clipboard: Mutex<[String: String]>

    /// - Parameters:
    ///   - gates: The grants this run has: none unless the developer passes `--allow`.
    ///   - clipboard: What the clipboard holds as the run starts, by pasteboard type.
    public init(gates: Set<GatedCapability> = [], clipboard: String? = nil) {
        self.gates = gates
        self.clipboard = Mutex(clipboard.map { [JSInput.plainTextType: $0] } ?? [:])
    }

    /// Every call so far, in order.
    public var recorded: [Call] { calls.withLock { $0 } }

    /// The plain text on the headless clipboard.
    public var clipboardText: String? { clipboard.withLock { $0[JSInput.plainTextType] } }

    /// For `JSHost(call:)`.
    public var serve: JSHost.Call {
        { [self] call, reply in reply(self.answer(call)) }
    }

    /// Checks one call, notes it, and answers it.
    public func answer(_ call: JSHostCall) -> JSHostAnswer {
        let answer = decide(call)
        calls.withLock { $0.append(Call(method: call.method, arguments: call.arguments, answer: answer)) }
        return answer
    }

    private func decide(_ call: JSHostCall) -> JSHostAnswer {
        if let method = HostMethod(rawValue: call.method) {
            if let gate = method.gate, !gates.contains(gate) { return Self.notGranted(call.method, gate) }
            return perform(method, call.arguments)
        }
        guard let gate = Self.groupGates[call.method] else {
            return .refused("There is no host method \(call.method).")
        }
        if let gate, !gates.contains(gate) { return Self.notGranted(call.method, gate) }
        return Self.notServed(call.method)
    }

    /// `HostAPIDispatcher`'s words for a call without its grant.
    static func notGranted(_ method: String, _ gate: GatedCapability) -> JSHostAnswer {
        .refused("\(method) needs the \(gate.rawValue) permission, which this extension does not have.")
    }

    private func perform(_ method: HostMethod, _ arguments: String) -> JSHostAnswer {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        guard let object else { return .refused("\(method.rawValue) was not given what it takes.") }
        switch method {
        case .copyText:
            guard let text = object["text"] as? String else { return .refused("copyText was not given what it takes.") }
            clipboard.withLock { $0 = [JSInput.plainTextType: text] }
            return .done
        case .copyContent, .pasteboardWrite:
            guard let content = object["content"] as? [String: String] else {
                return .refused("\(method.rawValue) was not given what it takes.")
            }
            let kept = content.filter { [JSInput.plainTextType, JSInput.htmlType, JSInput.rtfType].contains($0.key) }
            guard !kept.isEmpty else { return .refused("The content has no plain text, HTML or RTF in it.") }
            clipboard.withLock { $0 = kept }
            return .done
        case .pasteboardRead:
            let content = clipboard.withLock { $0 }
            guard let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) else {
                return .failed("The clipboard cannot be read now.")
            }
            return .value(String(decoding: data, as: UTF8.self))
        case .pasteText, .pasteContent, .performCommand, .pressKeys, .performService, .share,
             .showText, .showResult, .showSuccess, .showFailure, .showSettings, .appear,
             .openUrl, .openTemplateUrl, .revealFile:
            // Written down, and done: there is no destination, bar or browser to do it to.
            return .done
        case .richTextConvert, .dictionaryDefine, .spellingLanguages, .spellingPreferred, .spellingCheck, .spellingGuesses:
            return .failed("\(method.rawValue) is not available in a headless run.")
        }
    }
}
