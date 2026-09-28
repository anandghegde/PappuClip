import Foundation
import PappuCore

/// §8.10: where a module's `auth` secret is kept, and how Settings asks for a sign-in without knowing how
/// one is run.
///
/// The secret lives in the Keychain beside the extension's `secret` options, under the same key, so it is
/// bound to the install's local identity and instance exactly as they are (SEC-8a): another extension,
/// or another install of the same manifest identifier, has another identity and reads nothing. Its
/// option part, `#authsecret`, is one no manifest option can have, so no option shadows it.
public enum AuthSecret {
    /// The Keychain account's option part.
    public static let account = "#authsecret"
    /// What an action reads it as: `options.authsecret`.
    public static let option = "authsecret"
    /// The function a module extension signs in with.
    public static let function = "auth"
}

extension SecretStore {
    public func authSecret(of instance: InstanceID, owner: LocalIdentity) -> String? {
        secret(AuthSecret.account, of: instance, owner: owner)
    }

    /// An empty secret signs out.
    public func setAuthSecret(_ value: String, of instance: InstanceID, owner: LocalIdentity) throws {
        try setSecret(value, for: AuthSecret.account, of: instance, owner: owner)
    }
}

extension InstalledExtension {
    /// Its module exports `auth`, so Settings offers Sign In.
    public var signsIn: Bool {
        manifest.moduleSource != nil && moduleExports?.functions.contains(AuthSecret.function) == true
    }
}

/// Everything one sign-in runs with: the approved bytes, and who they are.
public struct SignInRequest: Sendable, Equatable {
    public var owner: LocalIdentity
    public var instance: InstanceID
    /// The approved bytes' digest.
    public var generation: String
    public var name: String
    public var identifier: String
    public var directory: URL
    public var module: ModuleSource
    /// The approval's grants, which `httpRequest` is checked against as it is for an action.
    public var gates: Set<GatedCapability>
    public var network: NetworkPolicy?
    /// `info.username`: the `username` option, if it has one.
    public var username: String
    /// `info.password`: typed for this sign-in and never stored.
    public var password: String

    public init(
        owner: LocalIdentity,
        instance: InstanceID,
        generation: String,
        name: String,
        identifier: String,
        directory: URL,
        module: ModuleSource,
        gates: Set<GatedCapability> = [],
        network: NetworkPolicy? = nil,
        username: String = "",
        password: String = ""
    ) {
        self.owner = owner
        self.instance = instance
        self.generation = generation
        self.name = name
        self.identifier = identifier
        self.directory = directory
        self.module = module
        self.gates = gates
        self.network = network
        self.username = username
        self.password = password
    }

    /// Nil unless the extension may sign in now: approved for these bytes, with an instance, and a module
    /// that exports `auth`.
    public init?(_ installed: InstalledExtension, password: String = "") {
        guard installed.signsIn,
              let module = installed.manifest.moduleSource,
              let approval = installed.approval,
              let digest = approval.digest,
              let instance = installed.instance
        else { return nil }
        self.init(
            owner: installed.identity,
            instance: instance,
            generation: digest.hex,
            name: installed.manifest.name.english,
            identifier: installed.manifest.identifier,
            directory: installed.directory,
            module: module,
            gates: approval.gates,
            network: NetworkPolicy(entitlements: installed.manifest.entitlements, networkHosts: installed.manifest.networkHosts),
            username: installed.storedOptions["username"] ?? "",
            password: password
        )
    }
}

public enum SignInOutcome: Sendable, Equatable {
    /// The secret is in the Keychain.
    case signedIn
    /// Why, in words that can be shown: never the secret or what the service sent.
    case failed(String)
    /// Nothing came back to the callback listener in time.
    case timedOut
    case cancelled
}

/// Runs a module's `auth` and keeps what it gives. The app's is `ExtensionSignIn`.
public protocol SigningIn: Sendable {
    func signIn(_ request: SignInRequest) async -> SignInOutcome
    /// Ends the sign-in in progress for `owner`, if there is one; it then comes to `cancelled`.
    func cancelSignIn(for owner: LocalIdentity) async
}
