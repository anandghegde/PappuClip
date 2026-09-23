import Foundation
import PappuAnalysis
import PappuDevTools
import Testing

/// The two documents the analyser is built from: `Resources/url-schemes.json` (FLT-2, PRD §7.5) and
/// `Resources/top-level-domains.txt` (FLT-2's "newer TLDs").
///
/// Read from the repository rather than from a bundle, because there is no app bundle to copy them
/// into yet. What is asserted is what the PRD settles and what the analyser depends on structurally;
/// the rest — IANA's exact count this week — is data these tests deliberately do not pin.
@Suite struct AnalysisResourceFileTests {
    static func root() throws -> URL {
        try RepositoryRoot.find(from: URL(filePath: #filePath))
    }

    static func schemes() throws -> URLSchemes {
        try URLSchemes.load(from: root().appending(path: "Resources/" + URLSchemes.fileName))
    }

    static func domains() throws -> TopLevelDomains {
        try TopLevelDomains.load(from: root().appending(path: "Resources/" + TopLevelDomains.fileName))
    }

    // MARK: url-schemes.json

    @Test func theShippedSchemeListLoadsAtTheSchemaThisBuildReads() throws {
        let schemes = try Self.schemes()
        #expect(schemes.schema == URLSchemes.supportedSchema)
        #expect(schemes.sequence >= 1)
        #expect(schemes.note != nil)
    }

    /// PRD §7.5 names these by hand, so they are not waiting on anything.
    @Test func everySchemeThePRDNamesIsOnTheList() throws {
        let schemes = try Self.schemes()
        for scheme in ["bluesky", "craftdocs", "evernote", "ftp", "hook", "message", "omnifocus", "spotify", "x-devonthink-item", "lt"] {
            #expect(schemes.contains(scheme), "\(scheme)")
        }
    }

    /// The list is what Open Link hands to `NSWorkspace`, so a scheme on it has to be one.
    @Test func noShippedSchemeIsMalformed() throws {
        let schemes = try Self.schemes()
        let grammar = try NSRegularExpression(pattern: #"\A[a-z][a-z0-9+.\-]*\z"#)
        for scheme in schemes.schemes {
            let range = NSRange(location: 0, length: (scheme as NSString).length)
            #expect(grammar.firstMatch(in: scheme, range: range) != nil, "\(scheme)")
            #expect(!scheme.hasSuffix(":"), "the list holds schemes without the colon: \(scheme)")
        }
        #expect(Set(schemes.schemes).count == schemes.schemes.count, "a scheme is listed twice")
    }

    /// `http` and `https` belong to detector 1, and listing them here would make every web address a
    /// second, non-http detection of itself.
    @Test func theWebSchemesAreNotOnTheList() throws {
        let schemes = try Self.schemes()
        for scheme in ["http", "https", "mailto"] {
            #expect(!schemes.contains(scheme), "\(scheme)")
        }
    }

    /// PRD §14: the list is reviewed rather than guessed, so a scheme that runs something arbitrary is
    /// not on it.
    @Test func noShippedSchemeIsOneThatRunsCode() throws {
        let schemes = try Self.schemes()
        for scheme in ["javascript", "data", "file", "vbscript", "shortcuts"] {
            #expect(!schemes.contains(scheme), "\(scheme)")
        }
    }

    @Test func schemesAreComparedWithoutCase() throws {
        let schemes = try Self.schemes()
        #expect(schemes.contains("OmniFocus"))
        #expect(schemes.contains("X-DEVONthink-Item"))
    }

    @Test func aDocumentFromTheFutureIsRefusedRatherThanRead() throws {
        let data = try Data(contentsOf: Self.root().appending(path: "Resources/" + URLSchemes.fileName))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schema"] = URLSchemes.supportedSchema + 1
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: URLSchemes.UnsupportedSchema.self) { try URLSchemes.decode(future) }
    }

    // MARK: top-level-domains.txt

    /// IANA's own version line, kept so a bug report can say how old the list is.
    @Test func theShippedDomainListSaysWhenItWasPublished() throws {
        let domains = try Self.domains()
        #expect(try #require(domains.version).contains("Version"))
    }

    /// Roughly 1,400 today. The bound is loose on purpose: it catches a truncated or half-written
    /// file, which is the failure mode that matters, without pinning a number IANA changes.
    @Test func theShippedDomainListIsWholeRatherThanTruncated() throws {
        let domains = try Self.domains()
        #expect(domains.count > 1_000)
        #expect(domains.count < 5_000)
    }

    @Test func theSuffixesFLT2CallsNewAreOnTheList() throws {
        let domains = try Self.domains()
        for suffix in ["com", "org", "net", "uk", "app", "dev", "page", "xyz", "cloud", "zip"] {
            #expect(domains.contains(suffix), "\(suffix)")
        }
    }

    /// The version line is a comment and the names are punycode in lower case, which is what
    /// `TopLevelDomains.contains` compares against.
    @Test func everyShippedNameIsALabelAndNotACommentOrABlankLine() throws {
        let contents = try String(
            contentsOf: Self.root().appending(path: "Resources/" + TopLevelDomains.fileName),
            encoding: .utf8
        )
        let grammar = try NSRegularExpression(pattern: #"\A(xn--)?[a-z0-9\-]{2,63}\z"#)
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let name = String(line)
            let range = NSRange(location: 0, length: (name as NSString).length)
            #expect(grammar.firstMatch(in: name, range: range) != nil, "\(name)")
        }
    }

    @Test func namesAreComparedWithoutCase() throws {
        #expect(try Self.domains().contains("COM"))
    }

    // MARK: The two together

    /// `ContentAnalyzer.bundled(in:)` is the shipping path; this is the same analyser over the same
    /// documents, read from the repository because there is no app bundle yet.
    @Test func anAnalyserOverTheShippedDocumentsDetectsWhatFLT2Names() throws {
        let analyzer = ContentAnalyzer(schemes: try Self.schemes(), domains: try Self.domains(), files: NoFileProbe())
        let result = analyzer.analyze("https://example.com, sam@example.org, pappuclip.app, omnifocus:///task/1")
        #expect(result.urls == ["https://example.com", "https://pappuclip.app"])
        #expect(result.emails == ["sam@example.org"])
        #expect(result.nonHTTPURLs == ["omnifocus:///task/1"])
    }
}
