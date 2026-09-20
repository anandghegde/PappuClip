import Foundation

/// Messages between SpikeLab and its JavaScript helper, for spike 5. Compiled into both targets.
///
/// Throwaway, like the rest of the spike. The product's messages are architecture §10.2 and will
/// live in PappuJSBridge; what carries over is the answer to "does `XPCSession` with `Codable` do".
enum JSHostService {
    /// The helper's bundle identifier, which is also the name launchd knows the service by.
    static let name = "app.pappuclip.SpikeLab.JSHost"
}

struct JSHostRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The mouse-down readiness check of JS-19.
        case ping
        case status
        /// Make a VM for `extensionID` and evaluate `source` in it.
        case load
        /// Call the extension's population function with `input`.
        case populate
        /// Run `script` in the extension's VM and hand back the result as a string.
        case evaluate
        /// The same, answered from the message handler itself, the way the plain `Codable` handler has to.
        /// There to measure what that costs the other VMs.
        case evaluateInLine
        case unloadAll
        /// Leave, so that the next session starts a cold process.
        case exit
    }

    var kind: Kind
    var extensionID: String?
    var source: String?
    var input: String?
    var script: String?

    init(_ kind: Kind, extensionID: String? = nil, source: String? = nil, input: String? = nil, script: String? = nil) {
        self.kind = kind
        self.extensionID = extensionID
        self.source = source
        self.input = input
        self.script = script
    }
}

struct JSHostReply: Codable, Sendable {
    var ok = true
    var error: String?
    /// Time spent inside the helper. The round trip less this is what the transport costs.
    var helperMs: Double?
    /// Titles only. A title can quote the selection, so they are counted and never recorded.
    var actionTitles: [String]?
    var value: String?
    var status: JSHostStatus?

    static func failure(_ error: String) -> JSHostReply {
        JSHostReply(ok: false, error: error)
    }
}

/// What the helper can say about itself that the app cannot see from outside.
struct JSHostStatus: Codable, Sendable {
    var pid: Int32
    /// `phys_footprint`, the figure Activity Monitor shows as Memory and the one jetsam goes by.
    var footprintBytes: UInt64
    var vmCount: Int
    /// Time since the process started, which tells a fresh process from one launchd kept.
    var uptimeMs: Double
    var sandboxContainer: Bool
    /// Whether the kernel hands out executable JIT memory. False is what makes JavaScriptCore interpret.
    var jitMemoryAvailable: Bool
    /// `errno` from a TCP connect to the loopback discard port. EPERM (1) is the sandbox refusing;
    /// ECONNREFUSED (61) is a process that may use the network and found nothing listening.
    var loopbackConnectErrno: Int32
    /// Whether a file in the user's real home directory can be read.
    var canReadOutsideContainer: Bool
}

/// Helper to app: one call of the host API (architecture §10.2, the blocking form).
struct JSHostCall: Codable, Sendable {
    var method: String
    var argument: String
}

struct JSHostCallReply: Codable, Sendable {
    var value: String
}
