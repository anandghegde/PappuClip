import ApplicationServices
import Foundation
import Security

/// The machine and build a result came from.
///
/// Results are committed to the repository, so nothing here identifies a person: no host name, no user
/// name, no home path. The signing block exists because the Accessibility grant is tied to the code
/// signature (PRD §12), which makes it part of every permission measurement.
public struct HarnessEnvironment: Sendable, Equatable, Codable {
    public struct Signing: Sendable, Equatable, Codable {
        public var identifier: String?
        public var teamID: String?
        /// Common name of the leaf certificate; nil for ad-hoc and unsigned code.
        public var authority: String?
        public var isAdHoc: Bool
        public var hardenedRuntime: Bool
        /// The code directory hash. It changes with every rebuild, which lets a run tell whether a
        /// permission outlived one.
        public var codeHash: String?
    }

    public var osVersion: String
    public var osBuild: String
    public var hardwareModel: String
    public var architecture: String
    public var bundleID: String?
    /// Nil when the process is unsigned or the query failed.
    public var signing: Signing?
    public var accessibilityTrusted: Bool

    public static func current() -> HarnessEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HarnessEnvironment(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion") ?? "unknown",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            architecture: architectureName,
            bundleID: Bundle.main.bundleIdentifier,
            signing: currentSigning(),
            accessibilityTrusted: AXIsProcessTrusted()
        )
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func currentSigning() -> Signing? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any],
              info[kSecCodeInfoIdentifier as String] != nil
        else { return nil }

        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        return Signing(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            authority: certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? },
            isAdHoc: codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            hardenedRuntime: codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            codeHash: (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        )
    }
}
