import Foundation
import Observation
import PappuCore
import PappuExtensions

/// Extension Info and the options sheet, decided where a test can read them (SEC-4a–b, ALM-6, §8.9).
///
/// Every write goes to the store — or, for a `secret`, to the Keychain — and is then announced through
/// `changed`, which is how the app rebuilds the catalog the bar resolves against and, for a revocation,
/// cancels the extension's running work (SEC-4b). This model does not cancel anything itself: it has no
/// runtime to reach, and the rule that a revocation must reach one is the app's to keep, in one place.
@MainActor @Observable
public final class ExtensionsModel {
    public enum Change: Sendable, Equatable {
        /// Grants, state or options: rebuild the catalog.
        case updated(LocalIdentity)
        /// Something it was allowed to do is no longer allowed: rebuild, and cancel what it is running.
        case revoked(LocalIdentity)
        case removed(LocalIdentity)
        /// SEC-1d, SEC-2: a suspended extension may run again: rebuild, and forget its crashes.
        case resumed(LocalIdentity)
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var identity: LocalIdentity
        public var name: String
        public var state: ExtensionState
        public var version: String?
        /// §S4's sentences for what it does when used.
        public var listed: [String]
        public var gates: [GateRow]
        public var options: [OptionRow]
        /// Set when the files could not be read, in which case there is nothing else to show.
        public var unreadable: String?
        /// §8.10: set when its module exports `auth`.
        public var signIn: SignInRow? = nil

        public var id: LocalIdentity { identity }
        public var isApproved: Bool { state == .enabled && unreadable == nil }
        /// SEC-1d, SEC-2: the watchdog stopped it, and Resume is what starts it again.
        public var isSuspended: Bool { state == .suspended }
        public var stateLabel: String { ExtensionsModel.label(for: state) }
    }

    /// SEC-4a: one gated capability and whether the active bytes have it.
    public struct GateRow: Sendable, Equatable, Identifiable {
        public var capability: GatedCapability
        public var sentence: String
        public var isGranted: Bool

        public var id: GatedCapability { capability }
    }

    /// §8.10: Sign In and Sign Out, and which account.
    public struct SignInRow: Sendable, Equatable {
        /// `authServiceLabel`, else the extension's name.
        public var service: String
        public var isSignedIn: Bool
        public var inProgress: Bool
        /// It may sign in now: approved, with an instance.
        public var isAvailable: Bool
    }

    /// One control on the generated sheet (§8.9).
    public struct OptionRow: Sendable, Equatable, Identifiable {
        public enum Control: Sendable, Equatable {
            case text(multiline: Bool)
            case toggle
            /// Values and what to call them, in the manifest's order.
            case choice([Choice])
            case secret
            /// Asked for by `auth` (§8.10) and never stored: held in memory until the next sign-in.
            case password
            case heading
        }

        public struct Choice: Sendable, Equatable, Hashable {
            public var value: String
            public var label: String
        }

        /// The option's identifier; a heading, which has none, is keyed by its position.
        public var id: String
        public var control: Control
        public var label: String
        public var help: String?
        /// The effective value (`OptionValues.effective`): what the user set, else the default.
        public var value: String

        public var isOn: Bool { value == OptionValues.on }
    }

    private let library: ExtensionLibrary
    private let secrets: any SecretStore
    private let locale: Locale
    private let changed: @MainActor (Change) async -> Void
    private let signing: (any SigningIn)?
    /// §8.10: `password` options typed for the next sign-in, never written anywhere.
    private var passwords: [LocalIdentity: [String: String]] = [:]
    private var signingIn: Set<LocalIdentity> = []

    public private(set) var rows: [Row] = []
    /// The last failure, said once under whatever the user was doing.
    public private(set) var failure: String?
    private var installed: [LocalIdentity: InstalledExtension] = [:]
    /// DEV-1: Settings → Developer, when the app has a library to load development folders into.
    public var development: DevelopmentModel?

    public init(
        library: ExtensionLibrary,
        secrets: any SecretStore,
        locale: Locale = .current,
        signIn: (any SigningIn)? = nil,
        changed: @escaping @MainActor (Change) async -> Void = { _ in }
    ) {
        self.library = library
        self.secrets = secrets
        self.locale = locale
        self.signing = signIn
        self.changed = changed
    }

    public func row(_ identity: LocalIdentity) -> Row? {
        rows.first { $0.identity == identity }
    }

    /// The row for an action's owner, as `CatalogAction.owner` and `ActionRow.owner` spell it.
    public func row(owner: String) -> Row? {
        LocalIdentity(owner).flatMap(row)
    }

    public func refresh() async {
        do {
            let current = try await library.installed()
            installed = Dictionary(uniqueKeysWithValues: current.extensions.map { ($0.identity, $0) })
            rows = current.extensions.map(row(for:)) + current.unreadable.map { unreadable in
                Row(
                    identity: unreadable.record.localIdentity,
                    name: unreadable.record.name,
                    state: unreadable.record.state,
                    version: unreadable.record.activeVersion?.short,
                    listed: [],
                    gates: [],
                    options: [],
                    unreadable: ExtensionStrings.unreadable(unreadable.reason)
                )
            }
        } catch {
            failure = ExtensionStrings.failed(String(describing: error))
        }
    }

    // MARK: Approval (EXM-15d, SEC-4)

    /// Approves the active version with the gates already granted: Approve is not a way of switching
    /// every gate on (EXM-5d).
    public func approve(_ identity: LocalIdentity) async {
        let granted = Set(row(identity)?.gates.filter(\.isGranted).map(\.capability) ?? [])
        await perform(.updated(identity)) { try await self.library.store.approve(identity, granting: granted) }
    }

    /// SEC-4b: every grant goes, and whatever it is running is cancelled.
    public func revoke(_ identity: LocalIdentity) async {
        await perform(.revoked(identity)) { try await self.library.store.revoke(identity) }
    }

    /// SEC-4a: one switch. Turning a gate off is a revocation — the extension may be using it right
    /// now — and turning one on needs the extension approved to begin with.
    public func setGate(_ gate: GatedCapability, granted: Bool, of identity: LocalIdentity) async {
        guard let row = row(identity) else { return }
        if granted {
            guard row.isApproved else { return }
            let gates = Set(row.gates.filter(\.isGranted).map(\.capability)).union([gate])
            await perform(.updated(identity)) { try await self.library.store.approve(identity, granting: gates) }
        } else {
            await perform(.revoked(identity)) { try await self.library.store.revoke(gate, of: identity) }
        }
    }

    /// SEC-1d, SEC-2: Resume. It runs again under the grants it had when it was stopped.
    public func resume(_ identity: LocalIdentity) async {
        await perform(.resumed(identity)) { try await self.library.store.resume(identity) }
    }

    public func uninstall(_ identity: LocalIdentity) async {
        await perform(.removed(identity)) {
            try await self.library.uninstall(identity)
            // SEC-3: an uninstalled extension's API keys go with it.
            try self.secrets.removeSecrets(of: identity)
        }
    }

    // MARK: Options (ALM-6, §8.9)

    /// Values are per instance; a `secret` goes to the Keychain and never to the store (SEC-3).
    public func setOption(_ value: String, for option: String, of identity: LocalIdentity) async {
        guard let installed = installed[identity], let instance = installed.instance,
              let schema = installed.manifest.options.first(where: { $0.identifier == option })
        else { return }
        switch schema.kind {
        case .heading:
            return
        case .password:
            passwords[identity, default: [:]][option] = value
        case .secret:
            await perform(.updated(identity)) {
                try self.secrets.setSecret(value, for: option, of: instance, owner: identity)
            }
        case .string, .boolean, .multiple:
            await perform(.updated(identity)) {
                try await self.library.store.setOptionValue(value, for: option, of: instance)
            }
        }
    }

    // MARK: Sign-in (§8.10)

    /// Runs the module's `auth`, which opens the browser; the secret it gives goes to the Keychain under
    /// this extension's identity and instance. The typed password is forgotten once it has been used.
    public func signIn(_ identity: LocalIdentity) async {
        guard let signing, let installed = installed[identity], !signingIn.contains(identity) else { return }
        let password = installed.manifest.options.first { $0.kind == .password }?.identifier.flatMap { passwords[identity]?[$0] } ?? ""
        guard let request = SignInRequest(installed, password: password) else { return }
        signingIn.insert(identity)
        rows = rows.map { row in
            guard row.identity == identity else { return row }
            var row = row
            row.signIn?.inProgress = true
            return row
        }
        let outcome = await signing.signIn(request)
        signingIn.remove(identity)
        passwords[identity] = nil
        failure = switch outcome {
        case .signedIn: nil
        case .timedOut: ExtensionStrings.signInTimedOut
        case .cancelled: nil
        case .failed(let why): ExtensionStrings.signInFailed(why)
        }
        await refresh()
        if outcome == .signedIn { await changed(.updated(identity)) }
    }

    public func cancelSignIn(_ identity: LocalIdentity) async {
        await signing?.cancelSignIn(for: identity)
    }

    /// Takes the stored secret away; the extension's actions then read `options.authsecret` as not
    /// signed in.
    public func signOut(_ identity: LocalIdentity) async {
        guard let instance = installed[identity]?.instance else { return }
        await perform(.updated(identity)) { try self.secrets.setAuthSecret("", of: instance, owner: identity) }
    }

    // MARK: Internals

    private func perform(_ change: Change, _ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            failure = nil
        } catch {
            failure = ExtensionStrings.failed(String(describing: error))
        }
        await refresh()
        await changed(change)
    }

    private func row(for installed: InstalledExtension) -> Row {
        Row(
            identity: installed.identity,
            name: installed.manifest.name.text(for: locale),
            state: installed.approval == nil && installed.record.state == .enabled ? .pendingApproval : installed.record.state,
            version: installed.record.activeVersion?.short,
            listed: ConsentPresenter.sentences(for: installed.capabilities),
            gates: installed.capabilities.gated.map {
                GateRow(
                    capability: $0,
                    sentence: ConsentPresenter.sentence(for: $0, in: installed.capabilities),
                    isGranted: installed.isGranted($0)
                )
            },
            options: optionRows(for: installed),
            unreadable: nil,
            signIn: signInRow(for: installed)
        )
    }

    private func signInRow(for installed: InstalledExtension) -> SignInRow? {
        guard installed.signsIn, signing != nil else { return nil }
        return SignInRow(
            service: installed.manifest.authServiceLabel?.text(for: locale) ?? installed.manifest.name.text(for: locale),
            isSignedIn: installed.instance.flatMap { secrets.authSecret(of: $0, owner: installed.identity) } != nil,
            inProgress: signingIn.contains(installed.identity),
            isAvailable: SignInRequest(installed) != nil
        )
    }

    private func optionRows(for installed: InstalledExtension) -> [OptionRow] {
        let options = installed.manifest.options
        let stored = installed.instance.map { secrets.secrets(for: options, of: $0, owner: installed.identity) } ?? [:]
        let values = OptionValues.effective(options, stored: installed.storedOptions, secrets: stored)
        return options.enumerated().compactMap { offset, option in
            guard !option.hidden else { return nil }
            let control: OptionRow.Control = switch option.kind {
            case .string: .text(multiline: option.multiline)
            case .boolean: .toggle
            case .multiple:
                .choice(option.values.enumerated().map { index, value in
                    OptionRow.Choice(
                        value: value,
                        label: option.valueLabels.indices.contains(index) ? option.valueLabels[index].text(for: locale) : value
                    )
                })
            case .secret: .secret
            case .password: .password
            case .heading: .heading
            }
            let label = option.label?.text(for: locale) ?? option.identifier ?? ""
            var help = option.description?.text(for: locale)
            if option.kind == .password { help = ExtensionStrings.passwordHelp }
            if option.kind == .secret { help = help ?? ExtensionStrings.secretHelp }
            return OptionRow(
                id: option.identifier ?? "heading-\(offset)",
                control: control,
                label: label,
                help: help,
                value: option.identifier.flatMap { values[$0] } ?? ""
            )
        }
    }

    nonisolated static func label(for state: ExtensionState) -> String {
        switch state {
        case .enabled: ExtensionStrings.stateEnabled
        case .pendingApproval: ExtensionStrings.statePending
        case .disabled: ExtensionStrings.stateDisabled
        case .suspended: ExtensionStrings.stateSuspended
        case .revoked: ExtensionStrings.stateRevoked
        }
    }
}
