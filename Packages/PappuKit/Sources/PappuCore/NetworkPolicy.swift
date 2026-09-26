import Foundation

/// Where an extension's JavaScript may send requests (JS-8, SEC-6, architecture §10.5).
///
/// The helper has no network of its own; every request is the app's `httpRequest`, which asks this
/// before anything leaves the machine, and again for every redirect. Two rules:
///
/// - **Hosts.** With `networkHosts`, a request's host must be one of them, compared without case and
///   exactly: `api.example.com` does not admit `example.com` or `x.api.example.com`. Without them the
///   extension needs the `network` grant, and then any host will do.
/// - **https.** A named host is reached over https. Plain http is kept for what never leaves the
///   machine or the local network: `localhost`, a numeric address, a name with no dot, `.local`.
public struct NetworkPolicy: Sendable, Equatable, Hashable {
    /// Nil for any host: the `network` entitlement without `networkHosts`, which is gated.
    public var hosts: [String]?

    public init(hosts: [String]?) {
        self.hosts = hosts.map { $0.map { $0.lowercased() } }
    }

    /// Nil without the `network` entitlement: then no request is made at all.
    public init?(entitlements: some Sequence<Entitlement>, networkHosts: [String]) {
        guard entitlements.contains(.network) else { return nil }
        self.init(hosts: networkHosts.isEmpty ? nil : networkHosts)
    }

    /// Why `url` may not be requested, in words that name the rule and never the address; nil when it may.
    public func refusal(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return "httpRequest only makes http and https requests."
        }
        guard let host = url.host()?.lowercased(), !host.isEmpty else {
            return "httpRequest was not given an address it may request."
        }
        if let hosts, !hosts.contains(host) {
            return "httpRequest may only reach the hosts the extension declares in networkHosts."
        }
        if scheme == "http", !Self.isLocal(host) {
            return "httpRequest reaches a named host only over https."
        }
        return nil
    }

    /// Hosts reached over plain http: the machine itself, an address rather than a name, a name with no
    /// dot, and multicast DNS.
    static func isLocal(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") { return true }
        if bare.contains(":") { return true } // IPv6
        if !bare.contains(".") { return true }
        return bare.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
