import Foundation

/// What the app and `PappuClipRunner.xpc` say to each other (architecture §2.1, §9.5).
///
/// The Runner exists for two kinds of call that block and cannot be interrupted from inside: running
/// an AppleScript, which waits on whatever app it talks to, and performing a Service, which waits on
/// the app that provides it. In the Runner, a call that never returns costs a process the app can
/// kill. In the app, it would cost the main thread.
///
/// Every value is already resolved when it is sent. The Runner is not told the selection, the
/// extension or its options, only the script to run and the strings to run it with: §8.7's
/// placeholders are filled in on the app's side, where the table is, so the Runner has no rules of
/// its own to get wrong.
public enum RunnerService {
    /// The service's bundle identifier, which is the name launchd knows it by.
    public static let name = "app.pappuclip.PappuClip.Runner"
}

public enum RunnerRequest: Codable, Sendable, Equatable {
    /// Who are you: the process identifier, which is what cancelling a job kills.
    case identify
    case appleScript(AppleScriptJob)
    case service(ServiceJob)
}

/// §8.4 AppleScript, ready to run.
public struct AppleScriptJob: Codable, Sendable, Equatable {
    public enum Source: Codable, Sendable, Equatable {
        /// Plain text with its placeholders already filled in.
        case text(String)
        /// An absolute path: `.applescript` source or a compiled `.scpt`.
        case file(String)
    }

    public var source: Source
    /// `appleScriptCall`: the handler to call instead of running the script's top level.
    public var handler: String?
    /// The handler's arguments, in order, each one already the value its parameter name stood for.
    public var arguments: [String]

    public init(source: Source, handler: String? = nil, arguments: [String] = []) {
        self.source = source
        self.handler = handler
        self.arguments = arguments
    }
}

/// §8.4 Service: a menu name and the text to hand it.
public struct ServiceJob: Codable, Sendable, Equatable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public enum RunnerReply: Codable, Sendable, Equatable {
    case identity(processID: Int32)
    /// It ran. What a script returned, as text, or nil for nothing (or for a Service, which returns
    /// nothing by definition).
    case returned(String?)
    case failed(RunnerFailure)
}

/// Why a job did not run to the end.
public struct RunnerFailure: Codable, Sendable, Equatable, Error {
    /// The AppleScript error number, or one of the Runner's own below.
    public var number: Int
    /// For the inspector and the developer console. Never shown as it stands: it can quote the script.
    public var message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    /// §8.4: an AppleScript that raises error 502 wants its settings looked at.
    public static let needsSettings = 502
    /// `errAEEventNotPermitted`: the user said no, or has not been asked, to this app controlling the
    /// one the script talks to (ONB-5).
    public static let automationDenied = -1743
    /// `userCanceledErr`, which a script raises when a dialog it put up is cancelled.
    public static let userCancelled = -128

    /// The Runner's own: the script would not compile or load.
    public static let doesNotCompile = -2740
    /// The Runner's own: no Service by that name, or it would not take the text.
    public static let serviceNotPerformed = -30_001
    /// The Runner's own: the request could not be read.
    public static let badRequest = -30_002
}
