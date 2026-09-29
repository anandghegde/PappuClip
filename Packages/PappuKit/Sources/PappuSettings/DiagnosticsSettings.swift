import Foundation
import Observation
import PappuDiagnostics
import SwiftUI

/// The two opt-ins (DIA-3, DIA-4), decided where a test can read them.
///
/// Both are off by default. Beta diagnostics are offered only in a beta build: elsewhere the switch is
/// not drawn at all. Turning either off makes the reporter discard what it collected for it.
@MainActor @Observable
public final class DiagnosticsModel {
    public private(set) var crashReports = false
    public private(set) var betaDiagnostics = false
    public private(set) var offersBetaDiagnostics = false
    /// Set by `showPreview`, cleared by `hidePreview`: what an upload would send, as it would send it.
    public private(set) var preview: Preview?

    public struct Preview: Sendable, Equatable, Identifiable {
        public var crashReports: String?
        public var betaDiagnostics: String?
        public var id: String { (crashReports ?? "") + (betaDiagnostics ?? "") }
    }

    private let reporter: DiagnosticsReporter

    public init(reporter: DiagnosticsReporter) {
        self.reporter = reporter
        refresh()
    }

    public func refresh() {
        let preferences = reporter.preferences
        crashReports = preferences.crashReports
        betaDiagnostics = preferences.betaDiagnostics
        offersBetaDiagnostics = preferences.offersBetaDiagnostics
    }

    public func setCrashReports(_ on: Bool) {
        reporter.preferences.setCrashReports(on)
        refresh()
    }

    public func setBetaDiagnostics(_ on: Bool) {
        reporter.preferences.setBetaDiagnostics(on)
        refresh()
    }

    public func showPreview() {
        let (crash, beta) = reporter.preview()
        preview = Preview(
            crashReports: crash.map { String(decoding: $0, as: UTF8.self) },
            betaDiagnostics: beta.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    public func hidePreview() {
        preview = nil
    }
}

/// The switches, as a section any Settings form can hold. It lives in General until Settings → App
/// exists to take it (PRD §7.5).
public struct DiagnosticsSettingsSection: View {
    let model: DiagnosticsModel

    public init(model: DiagnosticsModel) {
        self.model = model
    }

    public var body: some View {
        Section(DiagnosticsStrings.heading) {
            Toggle(DiagnosticsStrings.crashReports, isOn: Binding(
                get: { model.crashReports },
                set: { model.setCrashReports($0) }
            ))
            .accessibilityLabel(DiagnosticsStrings.crashReports)
            .accessibilityHint(DiagnosticsStrings.crashReportsHelp)
            Text(DiagnosticsStrings.crashReportsHelp).font(.caption).foregroundStyle(.secondary)
            if model.offersBetaDiagnostics {
                Toggle(DiagnosticsStrings.betaDiagnostics, isOn: Binding(
                    get: { model.betaDiagnostics },
                    set: { model.setBetaDiagnostics($0) }
                ))
                .accessibilityLabel(DiagnosticsStrings.betaDiagnostics)
                .accessibilityHint(DiagnosticsStrings.betaDiagnosticsHelp)
                Text(DiagnosticsStrings.betaDiagnosticsHelp).font(.caption).foregroundStyle(.secondary)
            }
            Text(DiagnosticsStrings.discarded).font(.caption).foregroundStyle(.secondary)
            Button(DiagnosticsStrings.showPreview) { model.showPreview() }
                .accessibilityLabel(DiagnosticsStrings.showPreview)
                .accessibilityHint(DiagnosticsStrings.showPreviewHelp)
                .help(DiagnosticsStrings.showPreviewHelp)
        }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.hidePreview() } })) { preview in
            DiagnosticsPreviewSheet(preview: preview) { model.hidePreview() }
        }
        .onAppear { model.refresh() }
    }
}

private struct DiagnosticsPreviewSheet: View {
    let preview: DiagnosticsModel.Preview
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DiagnosticsStrings.showPreviewHelp).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if preview.crashReports == nil && preview.betaDiagnostics == nil {
                        Text(DiagnosticsStrings.previewNothing)
                    }
                    if let text = preview.crashReports {
                        block(DiagnosticsStrings.previewCrashReports, text)
                    }
                    if let text = preview.betaDiagnostics {
                        block(DiagnosticsStrings.previewBetaDiagnostics, text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(DiagnosticsStrings.done, action: done)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(DiagnosticsStrings.done)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }
}
