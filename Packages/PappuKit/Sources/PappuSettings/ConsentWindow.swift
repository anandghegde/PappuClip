import AppKit
import PappuCore
import PappuExtensions
import SwiftUI

/// The install review (EXM-5a–d): the one window every install route passes through, and the app's
/// `ExtensionLibrary.Reviewer`.
///
/// Closing the window any way but a button is Cancel. The gate switches are `@State` that start empty,
/// so the only way a gated capability is granted is the user turning its switch on (EXM-5d).
@MainActor
public final class ConsentWindow {
    private var window: NSWindow?
    private var pending: CheckedContinuation<ExtensionLibrary.Consent, Never>?

    public init() {}

    /// Shows `proposal` and waits for the answer. A second review while one is open cancels the first:
    /// the library installs one at a time anyway, so this only happens when something has gone wrong.
    public func review(
        _ proposal: ExtensionLibrary.Proposal,
        name: @escaping (LocalIdentity) -> String? = { _ in nil }
    ) async -> ExtensionLibrary.Consent {
        answer(.cancel)
        let review = ConsentPresenter.review(proposal, name: name)
        return await withCheckedContinuation { continuation in
            pending = continuation
            let view = ConsentView(review: review) { [weak self] consent in self?.answer(consent) }
            let window = ConsentPanelWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = NSHostingController(rootView: view)
            window.title = review.title
            window.isReleasedWhenClosed = false
            window.onClose = { [weak self] in self?.answer(.cancel) }
            window.center()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func answer(_ consent: ExtensionLibrary.Consent) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: consent)
        let window = self.window
        self.window = nil
        (window as? ConsentPanelWindow)?.onClose = nil
        window?.close()
    }
}

private final class ConsentPanelWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        let onClose = self.onClose
        self.onClose = nil
        super.close()
        onClose?()
    }
}

struct ConsentView: View {
    let review: ConsentPresenter.Review
    let answer: (ExtensionLibrary.Consent) -> Void
    /// EXM-5d: empty, and nothing but a switch adds to it.
    @State private var granted: Set<GatedCapability> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.title).font(.title3.bold())
            if let provenance = review.provenance {
                Label(provenance, systemImage: "exclamationmark.shield").foregroundStyle(.secondary)
            }
            ForEach(review.collisions, id: \.self) { Text($0).foregroundStyle(.secondary) }

            if review.listed.isEmpty && review.gates.isEmpty {
                Text(ExtensionStrings.nothingAsked)
            }
            if !review.listed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ExtensionStrings.listedHeading).font(.headline)
                    ForEach(review.listed, id: \.self) { sentence in
                        Label(sentence, systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
                    }
                }
            }
            if !review.gates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ExtensionStrings.gatedHeading).font(.headline)
                    ForEach(review.gates) { gate in
                        Toggle(gate.sentence, isOn: Binding(
                            get: { granted.contains(gate.capability) },
                            set: { on in
                                if on { granted.insert(gate.capability) } else { granted.remove(gate.capability) }
                            }
                        ))
                    }
                }
            }

            HStack {
                ForEach(Array(review.choices.dropFirst().reversed()), id: \.self) { choice in
                    button(choice)
                }
                Spacer()
                if let first = review.choices.first {
                    button(first).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func button(_ choice: ConsentPresenter.Choice) -> some View {
        let label = ConsentPresenter.label(for: choice)
        if choice == .cancel {
            Button(label) { answer(.cancel) }.keyboardShortcut(.cancelAction)
        } else {
            Button(label) { answer(ConsentPresenter.consent(choice, granting: granted)) }
        }
    }
}
