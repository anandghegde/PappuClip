import Foundation
@testable import PappuExtensions
import Testing
import ZIPFoundation

/// SEC-8b's digest, and what staging refuses to copy.
@Suite struct PackageStagingTests {
    @Test func theDigestIgnoresListingOrderButNotPathsOrBytes() {
        let a = ContentDigest.of(files: [("Config.json", Data("{}".utf8)), ("b.js", Data("1".utf8))])
        let b = ContentDigest.of(files: [("b.js", Data("1".utf8)), ("Config.json", Data("{}".utf8))])
        let renamed = ContentDigest.of(files: [("Config.json", Data("{}".utf8)), ("c.js", Data("1".utf8))])
        let changed = ContentDigest.of(files: [("Config.json", Data("{}".utf8)), ("b.js", Data("2".utf8))])
        #expect(a == b)
        #expect(a != renamed)
        #expect(a != changed)
        #expect(a.hex.count == 64)
    }

    @Test func finderLitterIsLeftOut() throws {
        let scratch = try Scratch()
        let folder = try scratch.package(files: [".DS_Store": "x", "__MACOSX/._Config.json": "y", "sub/.DS_Store": "z"])
        #expect(try PackageStaging.regularFiles(under: folder) == ["Config.json"])
    }

    @Test func aSymbolicLinkIsRefused() throws {
        let scratch = try Scratch()
        let folder = try scratch.package()
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "passwd").path, withDestinationPath: "/etc/passwd")
        #expect(throws: PackageStaging.Failure.unsupportedEntry("passwd")) {
            try PackageStaging.copyFolder(folder, to: scratch.root.appending(path: "Out"))
        }
    }

    @Test func anArchiveEntryOutsideThePackageIsRefused() throws {
        let scratch = try Scratch()
        let url = scratch.root.appending(path: "Evil.popclipextz")
        let archive = try Archive(url: url, accessMode: .create)
        let data = Data("pwned".utf8)
        try archive.addEntry(with: "../escaped.txt", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
        #expect(throws: PackageStaging.Failure.escapesPackage("../escaped.txt")) {
            try PackageStaging.unzip(url, into: scratch.root.appending(path: "Out"))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appending(path: "escaped.txt").path))
    }

    @Test func anArchiveMustHoldOnePackage() throws {
        let scratch = try Scratch()
        let loose = scratch.root.appending(path: "Loose", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: loose.appending(path: "Config.json"))
        let archive = scratch.root.appending(path: "Loose.popclipextz")
        try FileManager.default.zipItem(at: loose, to: archive, shouldKeepParent: false)
        #expect(throws: PackageStaging.Failure.self) {
            try PackageStaging.unzip(archive, into: scratch.root.appending(path: "Out"))
        }
    }

    @Test func unzippingKeepsTheExecutableBitAndDropsTheRest() throws {
        let scratch = try Scratch()
        let folder = try scratch.package(files: ["run.sh": "echo hi"])
        try FileManager.default.setAttributes([.posixPermissions: 0o6777], ofItemAtPath: folder.appending(path: "run.sh").path)
        let package = try PackageStaging.unzip(try scratch.zip(folder), into: scratch.root.appending(path: "Out"))
        let mode = try FileManager.default.attributesOfItem(atPath: package.appending(path: "run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }
}
