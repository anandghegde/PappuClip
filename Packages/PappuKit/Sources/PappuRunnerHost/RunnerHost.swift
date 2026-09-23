import AppKit
import Carbon
import Foundation
import PappuRunnerBridge

/// What `PappuClipRunner.xpc` does with a request (architecture §9.5).
///
/// **On the main thread, one at a time.** `NSAppleScript` and `NSPerformService` are main-thread
/// APIs. That is also the design: a script that hangs holds the Runner's main thread and nothing
/// else, and the app's answer to a hang is to kill the Runner, not to wait for it.
///
/// **`NSAppleScript`, not OSAKit.** The architecture table says OSAKit. Both run a script and both
/// call a handler, but `NSAppleScript` is in Foundation and gives the error number directly, and
/// OSAKit would add a framework for no case the corpus has. The difference is invisible outside this
/// file.
public enum RunnerHost {
    /// Answers one request. Call on the main thread.
    @MainActor
    public static func handle(_ request: RunnerRequest) -> RunnerReply {
        switch request {
        case .identify:
            return .identity(processID: ProcessInfo.processInfo.processIdentifier)
        case .appleScript(let job):
            return run(job)
        case .service(let job):
            return perform(job)
        }
    }

    // MARK: AppleScript

    @MainActor
    static func run(_ job: AppleScriptJob) -> RunnerReply {
        let script: NSAppleScript?
        var error: NSDictionary?
        switch job.source {
        case .text(let source):
            script = NSAppleScript(source: source)
        case .file(let path):
            script = NSAppleScript(contentsOf: URL(fileURLWithPath: path), error: &error)
        }
        guard let script else { return .failed(failure(error, otherwise: RunnerFailure.doesNotCompile)) }
        // Compiled first, so that a syntax error is told apart from a runtime one.
        guard script.isCompiled || script.compileAndReturnError(&error) else {
            return .failed(failure(error, otherwise: RunnerFailure.doesNotCompile))
        }

        let result: NSAppleEventDescriptor
        if let handler = job.handler {
            result = script.executeAppleEvent(handlerCall(handler, job.arguments), error: &error)
        } else {
            result = script.executeAndReturnError(&error)
        }
        if let error { return .failed(failure(error, otherwise: -1)) }
        return .returned(text(of: result))
    }

    /// The Apple event that calls a handler by name: the same one `run script … with parameters`
    /// makes. AppleScript knows handlers by their lower-case names.
    static func handlerCall(_ handler: String, _ arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }

    /// What `after` is given: text for anything that has a text form, and nothing for a script whose
    /// last statement had no value.
    static func text(of result: NSAppleEventDescriptor) -> String? {
        if result.descriptorType == typeNull || result.descriptorType == typeType && result.typeCodeValue == typeNull {
            return nil
        }
        if let string = result.stringValue { return string }
        // A list of strings reads as its items one per line, as PopClip's scripts expect.
        if result.descriptorType == typeAEList, result.numberOfItems > 0 {
            let items = (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
            return items.isEmpty ? nil : items.joined(separator: "\n")
        }
        return nil
    }

    static func failure(_ error: NSDictionary?, otherwise number: Int) -> RunnerFailure {
        RunnerFailure(
            number: (error?[NSAppleScript.errorNumber] as? Int) ?? number,
            message: (error?[NSAppleScript.errorMessage] as? String) ?? (error?[NSAppleScript.errorBriefMessage] as? String) ?? ""
        )
    }

    // MARK: Service

    /// §8.4 Service: the text on a pasteboard of its own, so the user's clipboard is not touched.
    ///
    /// The pasteboard's name is unique to the call and released afterwards. A Service that returns
    /// something writes it back to this pasteboard, and it goes when the pasteboard goes: PopClip's
    /// Service actions have no output (§8.4), and a Service that edits text in place does it in the
    /// app it belongs to.
    @MainActor
    static func perform(_ job: ServiceJob) -> RunnerReply {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.pappuclip.runner.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        guard pasteboard.setString(job.text, forType: .string) else {
            return .failed(RunnerFailure(number: RunnerFailure.serviceNotPerformed, message: "The text could not be put on a pasteboard."))
        }
        guard NSPerformService(job.name, pasteboard) else {
            return .failed(RunnerFailure(number: RunnerFailure.serviceNotPerformed, message: "No Service called \(job.name) took the text."))
        }
        return .returned(nil)
    }
}
