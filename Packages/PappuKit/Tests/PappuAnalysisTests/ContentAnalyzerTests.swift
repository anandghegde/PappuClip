import Foundation
import PappuAnalysis
import PappuTestSupport
import Testing

/// FLT-2: what the analyser detects, and what it refuses to.
///
/// The lists and the disk are both injected, so every case here is a pure function of text plus data:
/// nothing depends on which top-level domains IANA published this week or on what is on the machine
/// running the tests. `AnalysisResourceFileTests` covers the shipped documents separately.
@Suite struct ContentAnalyzerTests {
    /// Enough of IANA's list to tell the cases apart, including the ones that are also file extensions.
    static let domains = TopLevelDomains(names: ["com", "org", "app", "dev", "uk", "md", "sh", "xn--p1ai"])

    static let schemes = URLSchemes(schemes: ["omnifocus", "x-devonthink-item", "message", "spotify", "ftp"])

    static func analyzer(
        files: any FileProbing = NoFileProbe(),
        limits: AnalysisLimits = .initial,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> ContentAnalyzer {
        ContentAnalyzer(schemes: schemes, domains: domains, files: files, limits: limits, now: now)
    }

    // MARK: Web addresses

    @Test func findsAWebAddressAndSaysWhereItIs() {
        let text = "the notes are at https://example.com/a?b=1 if you want them"
        let result = Self.analyzer().analyze(text)
        #expect(result.urls == ["https://example.com/a?b=1"])
        let span = try! #require(result.detections.first).span
        #expect(span.substring(of: text) == "https://example.com/a?b=1")
    }

    @Test func httpStaysHttpBecauseThatIsWhatTheUserSelected() {
        let result = Self.analyzer().analyze("http://example.com")
        #expect(result.urls == ["http://example.com"])
    }

    /// FLT-2: "scheme-less domains … normalised by adding `https://`". Not `http://`, which is what
    /// `NSDataDetector` hands back.
    @Test func aBareDomainGetsTheSchemeTheRequirementNames() {
        let result = Self.analyzer().analyze("go to example.com now")
        #expect(result.urls == ["https://example.com"])
        #expect(result.detections.first?.span.substring(of: "go to example.com now") == "example.com")
    }

    @Test func aBareDomainWithAPathKeepsThePath() {
        let result = Self.analyzer().analyze("example.com/docs/index")
        #expect(result.urls == ["https://example.com/docs/index"])
    }

    @Test func wwwIsADomainLikeAnyOther() {
        let result = Self.analyzer().analyze("www.example.org")
        #expect(result.urls == ["https://www.example.org"])
    }

    /// FLT-2's "including newer TLDs" — the whole reason the list is a bundled document.
    @Test func aNewTopLevelDomainIsADomain() {
        #expect(Self.analyzer().analyze("pappuclip.app").urls == ["https://pappuclip.app"])
        #expect(Self.analyzer().analyze("swift.dev").urls == ["https://swift.dev"])
    }

    /// Written in punycode, which is the form IANA's list is in and the only form the host detector
    /// can look up.
    @Test func anInternationalisedDomainWrittenInPunycodeIsADomain() {
        #expect(Self.analyzer().analyze("xn--e1afmkfd.xn--p1ai").urls == ["https://xn--e1afmkfd.xn--p1ai"])
    }

    /// Written in Cyrillic, which only the system detector can read — and it hands back the punycode,
    /// which is what has to reach `NSWorkspace` rather than the letters the user selected.
    @Test func anInternationalisedDomainIsNormalisedToThePunycodeAMacCanOpen() {
        let result = ContentAnalyzer(schemes: Self.schemes, domains: .none).analyze("пример.рф")
        #expect(result.urls == ["https://xn--e1afmkfd.xn--p1ai"])
        #expect(result.detections.first?.span.substring(of: "пример.рф") == "пример.рф")
    }

    /// The failure the list exists to prevent: a word with a dot in it is not a website.
    @Test func aWordWithADotInItIsNotADomain() {
        for text in ["Info.plist", "v2.0", "README.txt", "file.jpeg", "e.g. this", "foo.commercial"] {
            #expect(Self.analyzer().analyze(text).urls.isEmpty, "\(text)")
        }
    }

    @Test func aDomainInsideAnEmailIsTheEmail() {
        let result = Self.analyzer().analyze("write to sam@example.com")
        #expect(result.emails == ["sam@example.com"])
        #expect(result.urls.isEmpty)
    }

    // MARK: Email

    @Test func findsAnEmailWithoutTheMailtoTheUserDidNotType() {
        #expect(Self.analyzer().analyze("sam@example.com").emails == ["sam@example.com"])
        #expect(Self.analyzer().analyze("mailto:sam@example.com").emails == ["sam@example.com"])
    }

    // MARK: Other schemes

    @Test func findsASchemeFromTheBundledList() {
        let result = Self.analyzer().analyze("reopen omnifocus:///task/abc123 tomorrow")
        #expect(result.nonHTTPURLs == ["omnifocus:///task/abc123"])
    }

    @Test func aSchemeNobodyNamedIsLeftAsText() {
        let result = Self.analyzer().analyze("launch evil-scheme://run/everything")
        #expect(result.detections.isEmpty)
    }

    @Test func aSchemeWithNoListLoadedFindsNothingRatherThanGuessing() {
        let analyzer = ContentAnalyzer(schemes: .none, domains: Self.domains)
        #expect(analyzer.analyze("omnifocus:///task/abc123").detections.isEmpty)
    }

    /// The scheme pattern's lookbehind: a port is not a scheme.
    @Test func aPortIsNotASecondScheme() {
        let result = Self.analyzer().analyze("https://example.com:8080/here")
        #expect(result.urls == ["https://example.com:8080/here"])
        #expect(result.nonHTTPURLs.isEmpty)
    }

    // MARK: File paths

    @Test func findsAPathThatIsOnThisMac() {
        let disk = ScriptedFileProbe(present: ["/etc/hosts"])
        let result = Self.analyzer(files: disk).analyze("see /etc/hosts for the list")
        #expect(result.paths == ["/etc/hosts"])
    }

    @Test func aPathThatIsNotOnThisMacIsJustText() {
        let disk = ScriptedFileProbe()
        let result = Self.analyzer(files: disk).analyze("see /etc/hosts for the list")
        #expect(result.detections.isEmpty)
        #expect(disk.askedFor == ["/etc/hosts"])
    }

    /// FLT-2: "with `~` and `..` expanded". The value is the resolved path, because that is what
    /// Reveal in Finder would open.
    @Test func expandsTheTildeAndTheDotsBeforeLookingAndInTheValue() {
        let home = NSHomeDirectory()
        let disk = ScriptedFileProbe(present: [home + "/notes/today.txt", "/usr/lib"])
        let result = Self.analyzer(files: disk).analyze("~/notes/today.txt and /usr/local/../lib")
        #expect(result.paths == [home + "/notes/today.txt", "/usr/lib"])
    }

    /// The reason the path detector runs before the host detector: `.md` is a real top-level domain.
    @Test func aFileThatExistsIsAFileAndNotADomain() {
        let home = NSHomeDirectory()
        let disk = ScriptedFileProbe(present: [home + "/notes.md"])
        let result = Self.analyzer(files: disk).analyze("~/notes.md")
        #expect(result.paths == [home + "/notes.md"])
        #expect(result.urls.isEmpty)
    }

    @Test func anEscapedSpaceIsPartOfThePath() {
        let disk = ScriptedFileProbe(present: ["/Users/me/My Notes/a.txt"])
        let result = Self.analyzer(files: disk).analyze(#"open /Users/me/My\ Notes/a.txt please"#)
        #expect(result.paths == ["/Users/me/My Notes/a.txt"])
    }

    @Test func textWithNoPathInItTouchesNoDisk() {
        let disk = ScriptedFileProbe()
        _ = Self.analyzer(files: disk).analyze("nothing here but words and example.com")
        #expect(disk.askedFor.isEmpty)
    }

    // MARK: Ordering and overlap

    @Test func detectionsComeInTheOrderTheyAppearAndNeverOverlap() {
        let disk = ScriptedFileProbe(present: ["/etc/hosts"])
        let text = "sam@example.com, then https://example.org/x, then /etc/hosts, then other.app"
        let result = Self.analyzer(files: disk).analyze(text)
        #expect(result.detections.map(\.kind) == [.email, .url, .path, .url])
        for (earlier, later) in zip(result.detections, result.detections.dropFirst()) {
            #expect(earlier.span.location < later.span.location)
            #expect(!earlier.span.overlaps(later.span))
        }
    }

    // MARK: Punctuation

    @Test func sentencePunctuationIsNotPartOfTheAddress() {
        #expect(Self.analyzer().analyze("go to example.com.").urls == ["https://example.com"])
        #expect(Self.analyzer().analyze("go to example.com, then home").urls == ["https://example.com"])
        #expect(Self.analyzer().analyze("(example.com)").urls == ["https://example.com"])
    }

    @Test func aBracketTheAddressOwnsIsKept() {
        let text = "https://en.wikipedia.org/wiki/Foo_(bar)"
        #expect(Self.analyzer().analyze(text).urls == [text])
    }

    @Test func aSchemeFromTheListLosesItsTrailingFullStopToo() {
        let result = Self.analyzer().analyze("open spotify:track:4uLU6hMCjMI75M1A2tKUQC.")
        #expect(result.nonHTTPURLs == ["spotify:track:4uLU6hMCjMI75M1A2tKUQC"])
    }

    // MARK: The selection as a whole

    @Test func aSelectionThatIsOneAddressSaysSo() {
        #expect(Self.analyzer().analyze("  https://example.com  ").isSingleURL)
        #expect(Self.analyzer().analyze("example.com").isSingleURL)
        #expect(Self.analyzer().analyze("omnifocus:///task/1").isSingleURL)
        #expect(!Self.analyzer().analyze("go to example.com now").isSingleURL)
        #expect(!Self.analyzer().analyze("example.com and example.org").isSingleURL)
    }

    @Test func aSelectionThatIsOnePathIsNotAnAddress() {
        let disk = ScriptedFileProbe(present: ["/etc/hosts"])
        #expect(!Self.analyzer(files: disk).analyze("/etc/hosts").isSingleURL)
    }

    @Test func theFirstAddressIsTheOneAnActionNarrowsTo() {
        let result = Self.analyzer().analyze("sam@example.com and https://example.org and example.com")
        #expect(result.firstURL?.value == "https://example.org")
    }

    @Test func emptyTextIsAnEmptyAnalysis() {
        let result = Self.analyzer().analyze("")
        #expect(result.detections.isEmpty)
        #expect(!result.bounded)
        #expect(result.text.isEmpty)
    }

    @Test func nothingFoundIsStillTheWholeText() {
        let result = Self.analyzer().analyze("just some ordinary words")
        #expect(result.text == "just some ordinary words")
        #expect(result.detections.isEmpty)
        #expect(!result.bounded)
    }

    // MARK: Limits

    @Test func pastTheCharacterWindowNothingIsDetectedAndItSaysSo() {
        let limits = AnalysisLimits(maxCharacters: 20, maxDetections: 200, maxFileChecks: 32, fileCheckBudget: .milliseconds(8))
        let result = Self.analyzer(limits: limits).analyze("example.com then padding padding https://example.org")
        #expect(result.urls == ["https://example.com"])
        #expect(result.bounded)
    }

    @Test func theDetectionCapIsACeilingAndSaysSo() {
        let limits = AnalysisLimits(maxCharacters: 20_000, maxDetections: 2, maxFileChecks: 32, fileCheckBudget: .milliseconds(8))
        let result = Self.analyzer(limits: limits).analyze("a.com b.com c.com d.com")
        #expect(result.detections.count == 2)
        #expect(result.bounded)
    }

    @Test func theFileCheckCountStopsTheSearchAndSaysSo() {
        let disk = ScriptedFileProbe()
        let limits = AnalysisLimits(maxCharacters: 20_000, maxDetections: 200, maxFileChecks: 2, fileCheckBudget: .milliseconds(8))
        let result = Self.analyzer(files: disk, limits: limits).analyze("/a /b /c /d")
        #expect(disk.askedFor.count == 2)
        #expect(result.bounded)
    }

    /// The budget is what protects the 20 ms stage from a stalled network mount: each check costs
    /// time, and the analyser stops between checks rather than in the middle of one.
    @Test func theFileBudgetStopsTheSearchAndSaysSo() {
        let clock = ManualTimeSource()
        let disk = ScriptedFileProbe()
        disk.onEachCheck { clock.advance(by: .milliseconds(5)) }
        let limits = AnalysisLimits(maxCharacters: 20_000, maxDetections: 200, maxFileChecks: 32, fileCheckBudget: .milliseconds(8))
        let result = Self.analyzer(files: disk, limits: limits, now: clock.reader).analyze("/a /b /c /d")
        #expect(disk.askedFor == ["/a", "/b"])
        #expect(result.bounded)
    }

    @Test func aRunThatHitsNoLimitIsNotBounded() {
        let disk = ScriptedFileProbe(present: ["/etc/hosts"])
        #expect(!Self.analyzer(files: disk).analyze("/etc/hosts and example.com").bounded)
    }

    // MARK: The empty analyser

    /// `ContentAnalyzer.bundled(in:)` falls back to empty lists when a document is missing, and that
    /// has to degrade rather than misbehave: fewer detections, never wrong ones.
    @Test func withNoListsLoadedTheSystemDetectorStillWorks() {
        let analyzer = ContentAnalyzer(schemes: .none, domains: .none, files: NoFileProbe())
        #expect(analyzer.analyze("https://example.com").urls == ["https://example.com"])
        #expect(analyzer.analyze("sam@example.com").emails == ["sam@example.com"])
        #expect(analyzer.analyze("example.com").urls == ["https://example.com"])
        // The newer suffixes are the part that goes, because they are the part IANA's list supplies.
        #expect(analyzer.analyze("pappuclip.app").detections.isEmpty)
        #expect(analyzer.analyze("omnifocus:///task/1").detections.isEmpty)
    }

    /// Why the bundled list is worth having: `NSDataDetector` knows an older set of suffixes than
    /// IANA publishes, and FLT-2 asks for the newer ones by name.
    @Test func theNewerSuffixesComeFromTheListAndNotFromTheSystem() {
        let system = ContentAnalyzer(schemes: .none, domains: .none)
        for text in ["pappuclip.app", "swift.dev"] {
            #expect(system.analyze(text).detections.isEmpty, "\(text)")
            #expect(Self.analyzer().analyze(text).urls == ["https://" + text], "\(text)")
        }
    }
}
