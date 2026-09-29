import Foundation
import PappuDiagnostics
import PappuSelection

/// What of an attempt reaches beta diagnostics (DIA-4): one duration, filed under a stage.
///
/// An `AttemptRecord` holds the app's bundle identifier and pid, the route and the gesture — enough for
/// the inspector (DIA-2), and more than a diagnostics payload may carry. So nothing of it goes on but
/// `elapsed`, and only for an attempt that showed a bar.
enum DiagnosticsFeed {
    static func latency(of record: AttemptRecord) -> (stage: LatencyStage, duration: Duration)? {
        guard record.showedBar else { return nil }
        return (.selectionToBar, record.elapsed)
    }

    static func record(_ record: AttemptRecord, into reporter: DiagnosticsReporter) {
        guard let (stage, duration) = latency(of: record) else { return }
        reporter.record(duration, for: stage)
    }
}
