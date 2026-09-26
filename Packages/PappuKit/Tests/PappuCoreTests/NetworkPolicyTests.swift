import Foundation
import PappuCore
import Testing

/// JS-8, SEC-6: where an extension's JavaScript may send requests, decided before anything is sent.
@Suite struct NetworkPolicyTests {
    static func refusal(_ address: String, hosts: [String]? = ["api.example.com"]) -> String? {
        NetworkPolicy(hosts: hosts).refusal(for: URL(string: address)!)
    }

    /// SEC-6: a request to a host the extension did not declare fails, whatever else is right about it.
    @Test func aRequestToAnUndeclaredHostFails() {
        #expect(Self.refusal("https://api.example.com/v1?q=text") == nil)
        #expect(Self.refusal("https://API.Example.com/v1") == nil)
        let why = "httpRequest may only reach the hosts the extension declares in networkHosts."
        #expect(Self.refusal("https://example.com/") == why)
        #expect(Self.refusal("https://x.api.example.com/") == why)
        #expect(Self.refusal("https://api.example.com.evil.test/") == why)
        #expect(Self.refusal("https://evil.test/?api.example.com") == why)
        #expect(Self.refusal("https://api.example.com@evil.test/") == why)
    }

    /// A named host is reached over https; http is kept for what does not leave the machine or the
    /// local network.
    @Test func aNamedHostNeedsHttps() {
        let any: [String]? = nil
        #expect(Self.refusal("http://api.example.com/") == "httpRequest reaches a named host only over https.")
        #expect(Self.refusal("http://example.org/", hosts: any) == "httpRequest reaches a named host only over https.")
        for local in ["http://localhost:8080/", "http://printer.local/", "http://127.0.0.1/", "http://[::1]:3000/", "http://nas/", "http://dev.localhost/"] {
            #expect(Self.refusal(local, hosts: any) == nil, "\(local)")
        }
    }

    @Test func onlyHttpAndHttpsAreRequested() {
        #expect(Self.refusal("file:///etc/passwd", hosts: nil) == "httpRequest only makes http and https requests.")
        #expect(Self.refusal("ftp://api.example.com/", hosts: nil) == "httpRequest only makes http and https requests.")
    }

    /// Without the entitlement there is no policy, so no request at all; without hosts, any host.
    @Test func theEntitlementAndTheHostsMakeThePolicy() {
        #expect(NetworkPolicy(entitlements: [Entitlement.script], networkHosts: ["a.test"]) == nil)
        #expect(NetworkPolicy(entitlements: [Entitlement.network], networkHosts: [])?.hosts == nil)
        #expect(NetworkPolicy(entitlements: [Entitlement.network], networkHosts: ["A.Test"])?.hosts == ["a.test"])
    }
}
