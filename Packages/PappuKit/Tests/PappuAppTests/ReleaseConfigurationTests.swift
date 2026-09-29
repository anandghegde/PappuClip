import Foundation
import Testing

/// PRD §11.4, read as it is checked in: what a release is signed with, which entitlements each process
/// carries, and how Sparkle is wired. Scripts/release.sh builds, signs and verifies the real thing
/// (Scripts/verify-signature.sh); the release checklist covers notarization and an update end to end.
@Suite struct ReleaseConfigurationTests {
    static func repository() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: directory.appending(path: "App/project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository().appending(path: path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: repository().appending(path: path), encoding: .utf8)
    }

    // MARK: Entitlements

    /// Not sandboxed (Accessibility and the event tap are refused inside it), library validation kept,
    /// and nothing that would let a debugger in.
    @Test func theAppKeepsLibraryValidationAndIsNotSandboxed() throws {
        let entitlements = try Self.plist("App/PappuClip/PappuClip.entitlements")
        #expect(entitlements["com.apple.security.app-sandbox"] == nil)
        #expect(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == false)
        #expect(Set(entitlements.keys) == ["com.apple.security.cs.disable-library-validation"])
    }

    @Test func eachHelperHasItsOneEntitlement() throws {
        let runner = try Self.plist("App/PappuClipRunner/PappuClipRunner.entitlements")
        #expect(Set(runner.keys) == ["com.apple.security.automation.apple-events"])
        let jsHost = try Self.plist("App/PappuClipJSHost/PappuClipJSHost.entitlements")
        #expect(Set(jsHost.keys) == ["com.apple.security.app-sandbox"])
        #expect(jsHost["com.apple.security.app-sandbox"] as? Bool == true)
    }

    // MARK: Signing

    /// The hardened runtime on every target, and no debugging entitlement injected into a Release build.
    @Test func releaseBuildsUseTheHardenedRuntimeWithoutGetTaskAllow() throws {
        let project = try Self.text("App/project.yml")
        #expect(project.contains("ENABLE_HARDENED_RUNTIME: YES"))
        #expect(project.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO"))
        #expect(!project.contains("ENABLE_HARDENED_RUNTIME: NO"))
    }

    /// The release script signs every piece inside out with the runtime flag and a timestamp, checks the
    /// result, and notarizes with a keychain profile named in the environment, never a password.
    @Test func theReleaseScriptSignsNotarizesAndStaples() throws {
        let script = try Self.text("Scripts/release.sh")
        #expect(script.contains("--options runtime"))
        #expect(script.contains("PAPPU_RELEASE_IDENTITY"))
        #expect(script.contains("Developer ID Application:"))
        #expect(script.contains("notarytool submit"))
        #expect(script.contains("--keychain-profile \"$PAPPU_NOTARY_PROFILE\""))
        #expect(script.contains("stapler staple"))
        #expect(script.contains("verify-signature.sh"))
        #expect(!script.contains("--password"))
        for helper in ["Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app", "PappuClipRunner.xpc", "PappuClipJSHost.xpc"] {
            #expect(script.contains(helper), "release.sh does not sign \(helper)")
        }
    }

    /// Without credentials a release stops before building and names what is missing.
    @Test func aReleaseWithoutCredentialsFailsAndSaysWhy() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [try Self.repository().appending(path: "Scripts/release.sh").path]
        var environment = ProcessInfo.processInfo.environment
        for key in ["PAPPU_RELEASE_IDENTITY", "PAPPU_NOTARY_PROFILE", "PAPPU_SPARKLE_PUBLIC_KEY", "PAPPU_APPCAST_URL"] {
            environment[key] = nil
        }
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 1)
        for key in ["PAPPU_RELEASE_IDENTITY", "PAPPU_NOTARY_PROFILE", "PAPPU_SPARKLE_PUBLIC_KEY", "PAPPU_APPCAST_URL"] {
            #expect(message.contains(key), "the failure does not name \(key)")
        }
        #expect(message.contains("Nothing was built"))
    }

    // MARK: Sparkle

    /// The feed and the public key come from build settings, so no key is ever committed, and every
    /// archive is checked before it is unpacked.
    @Test func sparklesKeysComeFromBuildSettings() throws {
        let info = try Self.plist("App/PappuClip/Info.plist")
        #expect(info["SUFeedURL"] as? String == "$(PAPPU_APPCAST_URL)")
        #expect(info["SUPublicEDKey"] as? String == "$(PAPPU_SPARKLE_PUBLIC_KEY)")
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        // Not sandboxed: Sparkle installs in-process and needs neither XPC service.
        #expect(info["SUEnableInstallerLauncherService"] == nil)
        #expect(info["SUEnableDownloaderService"] == nil)
        let project = try Self.text("App/project.yml")
        #expect(project.contains("PAPPU_SPARKLE_PUBLIC_KEY: \"\""))
        #expect(project.contains("PAPPU_APPCAST_URL: \"\""))
    }

    /// Sparkle is compiled in only by the release script: a development certificate has no Team ID,
    /// and library validation refuses to load the framework into such a process.
    @Test func onlyAReleaseBuildCompilesSparkleIn() throws {
        let project = try Self.text("App/project.yml")
        #expect(project.contains("PAPPU_UPDATER_CONDITION: \"\""))
        #expect(project.contains("$(PAPPU_UPDATER_CONDITION)"))
        #expect(project.contains("-dead_strip_dylibs"))
        #expect(try Self.text("Scripts/release.sh").contains("PAPPU_UPDATER_CONDITION=PAPPU_SPARKLE"))
        let updater = try Self.text("App/PappuClip/SparkleUpdater.swift")
        #expect(updater.contains("#if PAPPU_SPARKLE"))
    }

    /// The appcast script never takes a key on its command line or from inside the repository.
    @Test func theAppcastKeyStaysOutOfTheRepository() throws {
        let script = try Self.text("Scripts/appcast.sh")
        #expect(script.contains("--ed-key-file -"))
        #expect(script.contains("must not live inside the repository"))
        let ignored = try Self.text(".gitignore")
        #expect(ignored.contains("*.key"))
        #expect(ignored.contains("*eddsa*"))
    }
}
