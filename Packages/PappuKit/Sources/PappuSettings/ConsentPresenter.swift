import Foundation
import PappuCore
import PappuExtensions

/// What the install review says, decided where a test can read it (EXM-5a–d, safety spec §S4).
///
/// The analysis (`CapabilityAnalyzer`) says what an extension *can do*; this turns that into sentences
/// and into the choices the identity decision allows. It never grants anything itself: the answer is a
/// `Consent`, and `ExtensionLibrary.install` keeps only the gates the analysis found.
///
/// **Two levels, as §S4 has them.** Listed capabilities are read and accepted together by the one
/// Install button (EXM-5c). Gated ones are each a switch, and every switch starts at "Don't Allow"
/// (EXM-5d): `Review.gates` carries no initial value because there is only one, and the sheet that
/// draws it cannot choose another.
public enum ConsentPresenter {
    /// One switch on the review, and in Extension Info.
    public struct Gate: Sendable, Equatable, Identifiable {
        public var capability: GatedCapability
        public var sentence: String

        public var id: GatedCapability { capability }
    }

    /// A button on the review. Which ones exist is the identity decision's (EXM-2, SEC-8e).
    public enum Choice: Sendable, Hashable {
        case install
        /// The same identity's next version, which only a publisher can offer.
        case update
        case installSeparately
        /// A trust transition: the new install replaces this one (SEC-8e).
        case replace(LocalIdentity)
        case cancel
    }

    public struct Review: Sendable, Equatable {
        public var title: String
        /// SEC-8b: said for every local install, and never softened.
        public var provenance: String?
        /// One sentence per installed extension this one will sit beside.
        public var collisions: [String]
        public var listed: [String]
        public var gates: [Gate]
        /// In the order the buttons are drawn, the default first and Cancel last.
        public var choices: [Choice]
    }

    /// - Parameter name: an installed extension's name, for the collision sentence.
    public static func review(
        _ proposal: ExtensionLibrary.Proposal,
        locale: Locale = .current,
        name: (LocalIdentity) -> String? = { _ in nil }
    ) -> Review {
        let extensionName = proposal.manifest.name.text(for: locale)
        var collisions: [String] = []
        var choices: [Choice]
        var title = ExtensionStrings.installTitle(extensionName)
        switch proposal.decision {
        case .replacementOffered:
            title = ExtensionStrings.updateTitle(extensionName)
            choices = [.update, .installSeparately]
        case .separate(let found):
            choices = [.install]
            for collision in found {
                collisions.append(ExtensionStrings.collision(name(collision.existing) ?? extensionName))
                if collision.allowsTrustTransition { choices.append(.replace(collision.existing)) }
            }
        case .fresh, .alreadyInstalled:
            choices = [.install]
        }
        choices.append(.cancel)

        var provenance: String?
        if case .local = proposal.provenance { provenance = ExtensionStrings.fromThisMac }

        return Review(
            title: title,
            provenance: provenance,
            collisions: collisions,
            listed: sentences(for: proposal.capabilities),
            gates: gates(of: proposal.capabilities),
            choices: choices
        )
    }

    /// The review's answer. `granted` is what the user switched on; Cancel grants nothing whatever the
    /// switches say.
    public static func consent(_ choice: Choice, granting granted: Set<GatedCapability>) -> ExtensionLibrary.Consent {
        switch choice {
        case .install, .update: ExtensionLibrary.Consent(.install, granting: granted)
        case .installSeparately: ExtensionLibrary.Consent(.installSeparately, granting: granted)
        case .replace(let identity): ExtensionLibrary.Consent(.replaceByTrustTransition(identity), granting: granted)
        case .cancel: .cancel
        }
    }

    public static func label(for choice: Choice) -> String {
        switch choice {
        case .install: ExtensionStrings.install
        case .update: ExtensionStrings.update
        case .installSeparately: ExtensionStrings.installSeparately
        case .replace: ExtensionStrings.replace
        case .cancel: ExtensionStrings.cancel
        }
    }

    // MARK: Sentences

    /// The listed capabilities, then the apps its AppleScripts name (SEC-7a).
    public static func sentences(for capabilities: CapabilitySet) -> [String] {
        var sentences = capabilities.listed.map(sentence(for:))
        if !capabilities.controlledApps.isEmpty {
            sentences.append(ExtensionStrings.controlsApps(list(capabilities.controlledApps)))
        }
        return sentences
    }

    public static func gates(of capabilities: CapabilitySet) -> [Gate] {
        capabilities.gated.map { Gate(capability: $0, sentence: sentence(for: $0)) }
    }

    public static func sentence(for capability: ListedCapability) -> String {
        switch capability {
        case .opensWebPage(let host, true): ExtensionStrings.sendsTextToHost(host)
        case .opensWebPage(let host, false): ExtensionStrings.opensHost(host)
        case .opensConfiguredURL(true): ExtensionStrings.opensConfiguredURLWithText
        case .opensConfiguredURL(false): ExtensionStrings.opensConfiguredURL
        case .opensAppLink(let scheme, true): ExtensionStrings.sendsTextToAppLink(scheme)
        case .opensAppLink(let scheme, false): ExtensionStrings.opensAppLink(scheme)
        case .pressesKeys(let keys): ExtensionStrings.pressesKeys(list(keys))
        case .runsService(let name): ExtensionStrings.runsService(name)
        case .runsShortcut(let name): ExtensionStrings.runsShortcut(name)
        case .readsAndReplacesText: ExtensionStrings.readsAndReplacesText
        case .runsOnEveryAppearance: ExtensionStrings.runsOnEveryAppearance
        case .sendsData(let hosts): ExtensionStrings.sendsData(list(hosts))
        }
    }

    public static func sentence(for gate: GatedCapability) -> String {
        switch gate {
        case .script: ExtensionStrings.gateScript
        case .network: ExtensionStrings.gateNetwork
        case .syntheticInput: ExtensionStrings.gateSyntheticInput
        case .unboundedCode: ExtensionStrings.gateUnboundedCode
        }
    }

    private static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}
