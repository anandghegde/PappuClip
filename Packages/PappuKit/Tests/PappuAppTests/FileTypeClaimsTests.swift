import Foundation
import PappuCore
import PappuExtensions
import Testing

/// EXM-4: what the app's Info.plist claims, read as it is checked in.
///
/// PappuClip opens PopClip's extension files as an alternate handler and never as their owner, so a
/// Mac with PopClip keeps opening them in PopClip by default. PopClip's types are imported, never
/// exported, which leaves PopClip as the app that defines them. The build copies this file into the
/// bundle unchanged (`GENERATE_INFOPLIST_FILE: NO`); the manual checklist confirms the built copy.
@Suite struct FileTypeClaimsTests {
    static let popClipTypes: Set<String> = [
        "com.pilotmoon.popclip.extension",
        "com.pilotmoon.popclip.extension.zipped",
        "com.pilotmoon.popclip.extension.text",
    ]
    static let popClipSuffixes: Set<String> = ["popclipext", "popclipextz", "popcliptxt"]

    static func infoPlist() throws -> [String: Any] {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appending(path: "App/PappuClip/Info.plist")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                return try #require(plist as? [String: Any])
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func documentTypes() throws -> [[String: Any]] {
        try #require(infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
    }

    static func declarations(_ key: String) throws -> [[String: Any]] {
        try infoPlist()[key] as? [[String: Any]] ?? []
    }

    static func suffixes(of declaration: [String: Any]) -> [String] {
        let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
        return tags?["public.filename-extension"] as? [String] ?? []
    }

    @Test func popClipTypesAreClaimedOnlyAsAnAlternate() throws {
        var claimed: Set<String> = []
        for type in try Self.documentTypes() {
            let suffixes = Set(type["CFBundleTypeExtensions"] as? [String] ?? [])
            let contentTypes = Set(type["LSItemContentTypes"] as? [String] ?? [])
            let isPopClip = !suffixes.isDisjoint(with: Self.popClipSuffixes)
                || !contentTypes.isDisjoint(with: Self.popClipTypes)
            guard isPopClip else { continue }
            #expect(type["LSHandlerRank"] as? String == "Alternate", "\(suffixes) must be Alternate")
            #expect(type["CFBundleTypeRole"] as? String == "Viewer")
            // A document type that mixes our own suffixes with PopClip's would drag them to Alternate
            // too, or PopClip's up to Owner.
            #expect(suffixes.isSubset(of: Self.popClipSuffixes))
            #expect(contentTypes.isSubset(of: Self.popClipTypes))
            claimed.formUnion(contentTypes)
        }
        #expect(claimed == Self.popClipTypes)
    }

    @Test func popClipTypesAreImportedAndNeverExported() throws {
        let exported = try Self.declarations("UTExportedTypeDeclarations")
            .compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(!exported.contains { $0.hasPrefix("com.pilotmoon.") })
        #expect(exported.allSatisfy { $0.hasPrefix(ProductIdentity.bundleIDPrefix + ".") })

        let imported = try Self.declarations("UTImportedTypeDeclarations")
        let identifiers = Set(imported.compactMap { $0["UTTypeIdentifier"] as? String })
        #expect(identifiers == Self.popClipTypes)
        // Declared exactly as PopClip exports them, so the two declarations agree.
        let expected: [String: (suffix: String, conforms: Set<String>)] = [
            "com.pilotmoon.popclip.extension": ("popclipext", ["public.directory", "com.apple.package"]),
            "com.pilotmoon.popclip.extension.zipped": ("popclipextz", ["public.data"]),
            "com.pilotmoon.popclip.extension.text": ("popcliptxt", ["public.plain-text"]),
        ]
        for declaration in imported {
            let identifier = try #require(declaration["UTTypeIdentifier"] as? String)
            let want = try #require(expected[identifier])
            #expect(Self.suffixes(of: declaration) == [want.suffix])
            #expect(Set(declaration["UTTypeConformsTo"] as? [String] ?? []) == want.conforms)
        }
    }

    @Test func pappuClipOwnsOnlyItsOwnTypes() throws {
        for type in try Self.documentTypes() where type["LSHandlerRank"] as? String == "Owner" {
            let suffixes = type["CFBundleTypeExtensions"] as? [String] ?? []
            #expect(suffixes.allSatisfy { $0.hasPrefix("pappu") })
            let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
            #expect(contentTypes.allSatisfy { $0.hasPrefix(ProductIdentity.bundleIDPrefix + ".") })
        }
        // Nothing is ever claimed as Default: that rank would contend with PopClip's own.
        #expect(try Self.documentTypes().allSatisfy { $0["LSHandlerRank"] as? String != "Default" })
    }

    @Test func claimedSuffixesMatchTheProductIdentityAndOpenAsAnInstall() throws {
        let identity = Set(
            ProductIdentity.FileExtension.package + ProductIdentity.FileExtension.zippedPackage
                + ProductIdentity.FileExtension.snippet + ProductIdentity.FileExtension.codeSnippet
        )
        var claimed: Set<String> = []
        for type in try Self.documentTypes() {
            claimed.formUnion(type["CFBundleTypeExtensions"] as? [String] ?? [])
        }
        let declared = try (Self.declarations("UTExportedTypeDeclarations")
            + Self.declarations("UTImportedTypeDeclarations")).flatMap(Self.suffixes)
        #expect(claimed == identity)
        #expect(Set(declared).isSubset(of: claimed))
        // Every suffix the app says it opens reaches the install review.
        for suffix in claimed {
            let url = URL(filePath: "/tmp/Example.\(suffix)")
            #expect(ExtensionLibrary.Source.file(url) != nil, "\(suffix) does not route to an install")
        }
        // PopClip's settings and licence files are PopClip's alone.
        #expect(!claimed.contains("popclipconfig"))
        #expect(!claimed.contains("popcliplicense"))
    }
}
