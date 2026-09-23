import Foundation

/// The app a read is aimed at.
///
/// The pid pins it: a bundle identifier alone would also match a second copy of the app, and a permit
/// has to name the one process the reader will talk to.
public struct TargetApp: Sendable, Equatable, Codable {
    public let pid: pid_t
    public let bundleID: String?

    public init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// How much of the target a permit opens (architecture §4.4 step 4).
public enum ReadScope: String, Sendable, Codable, CaseIterable {
    /// Page metadata only. Website hard blocks need the URL before they can judge the text, so the
    /// gate opens that much and no more (ACT-17b, 1.0).
    case metadataOnly
    /// The selection itself.
    case fullText
}

/// Proof that §S1 steps 1–3 ran and passed, for this route and this process.
///
/// `init` is internal to this module, so `PrivacyGate` is the only thing in the program that can make
/// one; a reader takes it as a parameter, so a path that skips the gate does not compile
/// (architecture §3.1). It is `~Copyable` and consumed by the read it authorises, so a permit cannot
/// be kept and spent twice.
public struct ReadPermit: ~Copyable, Sendable {
    public let route: ActivationRoute
    public let target: TargetApp
    public let scope: ReadScope
    /// Never contains selection text; see `PrivacyTrace`.
    public let trace: PrivacyTrace

    init(route: ActivationRoute, target: TargetApp, scope: ReadScope, trace: PrivacyTrace) {
        self.route = route
        self.target = target
        self.scope = scope
        self.trace = trace
    }
}
