import AppKit
import PappuCore
import PappuExtensions
import SwiftUI

/// The batch review (EXM-15a–d): one window for a set of extensions arriving together, and the app's
/// `ExtensionLibrary.BatchReviewer`.
///
/// Closing it any way but Install installs nothing. The gated switches are `@State` that start empty,
/// so a gated extension is approved only by the user turning its own switch on (EXM-15c).
@MainActor
public final class BatchConsentWindow {
    private var window: NSWindow?
    private var pending: CheckedContinuation<[ExtensionLibrary.BatchApproval]?, Never>?

    public init() {}

    public func review(
        _ proposals: [ExtensionLibrary.Proposal],
        name: @escaping (LocalIdentity) -> String? = { _ in nil }
    ) async -> [ExtensionLibrary.BatchApproval]? {
        answer(nil)
        let review = BatchConsentPresenter.review(proposals, name: name)
        return await withCheckedContinuation { continuation in
            pending = continuation
            let view = BatchConsentView(review: review) { [weak self] answers in self?.answer(answers) }
            let window = BatchPanelWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = NSHostingController(rootView: view)
            window.title = review.title
            window.isReleasedWhenClosed = false
            window.onClose = { [weak self] in self?.answer(nil) }
            window.center()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func answer(_ answers: [ExtensionLibrary.BatchApproval]?) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: answers)
        let window = self.window
        self.window = nil
        (window as? BatchPanelWindow)?.onClose = nil
        window?.close()
    }
}

private final class BatchPanelWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        let onClose = self.onClose
        self.onClose = nil
        super.close()
        onClose?()
    }
}

struct BatchConsentView: View {
    let review: BatchConsentPresenter.Review
    let answer: ([ExtensionLibrary.BatchApproval]?) -> Void
    /// EXM-15c: empty, and nothing but a switch adds to it.
    @State private var switchedOn: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.title).font(.title3.bold())
            Label(review.provenance, systemImage: "exclamationmark.shield").foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !review.listedOnly.isEmpty {
                        Text(BatchStrings.listedHeading).font(.headline)
                        ForEach(review.listedOnly) { row in
                            rowDetail(row, title: Text(row.name).bold())
                        }
                    }
                    if !review.gated.isEmpty {
                        Text(BatchStrings.gatedHeading).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(review.gated) { row in
                            rowDetail(row, title: Toggle(isOn: binding(row.id)) { Text(row.name).bold() }
                                .accessibilityLabel(BatchStrings.switchLabel(row.name))
                                .accessibilityHint(row.gates.map(\.sentence).joined(separator: " ")))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 420)

            HStack {
                Button(BatchStrings.cancel) { answer(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(review.confirm) {
                    answer(BatchConsentPresenter.answers(review, switchedOn: switchedOn))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 500)
    }

    private func binding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { switchedOn.contains(id) },
            set: { on in
                if on { switchedOn.insert(id) } else { switchedOn.remove(id) }
            }
        )
    }

    private func rowDetail(_ row: BatchConsentPresenter.Row, title: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title
            if let collision = row.collision {
                Text(collision).font(.caption).foregroundStyle(.secondary)
            }
            if row.listed.isEmpty && row.gates.isEmpty {
                Text(BatchStrings.nothingAsked).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(row.listed, id: \.self) { sentence in
                Label(sentence, systemImage: "checkmark.circle").font(.callout)
            }
            ForEach(row.gates) { gate in
                Label(gate.sentence, systemImage: "exclamationmark.triangle").font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
