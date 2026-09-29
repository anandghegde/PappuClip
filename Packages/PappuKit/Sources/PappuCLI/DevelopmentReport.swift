import Foundation
import PappuJSBridge

/// What `pappuclip run` prints for an outcome: the script's own lines and the calls it made, then the
/// result. Kept here, out of the executable, so that it is tested.
public enum DevelopmentReport {
    public struct Line: Sendable, Equatable {
        public var text: String
        /// Standard error rather than standard output.
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    public static func lines(for outcome: DevelopmentRun.Outcome, showingCalls: Bool = true) -> [Line] {
        var lines = outcome.log.map { Line(text: $0, isError: false) }
        if showingCalls {
            for call in outcome.calls {
                lines.append(Line(text: "host: \(call.method) \(call.arguments) -> \(describe(call.answer))", isError: true))
            }
        }
        switch outcome.ending {
        case .returned(let value):
            if let value { lines.append(Line(text: value, isError: false)) }
            lines.append(Line(text: "passed", isError: true))
        case .threw(let why):
            lines.append(Line(text: "failed: \(why)", isError: true))
        case .notRun(let why):
            lines.append(Line(text: "error: \(why)", isError: true))
        case .timedOut:
            lines.append(Line(text: "failed: still running at the timeout", isError: true))
        }
        return lines
    }

    static func describe(_ answer: JSHostAnswer) -> String {
        switch answer {
        case .done: "done"
        case .value(let json): json
        case .refused(let why): "refused: \(why)"
        case .failed(let why): "failed: \(why)"
        }
    }
}
