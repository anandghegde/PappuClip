import Foundation
import PappuCore
import Testing

/// The parts of the model that M2 week 1 added: §8.5 step 4, and a parsed manifest's round trip.
@Suite struct ParsedManifestTests {
    static func action(regex: String?, requirements: [String] = ["text"]) -> ActionManifest {
        ActionManifest(
            title: "Test",
            requirements: requirements.map(ActionRequirement.init(parsing:)),
            regex: regex,
            executor: .url(URLAction(template: "https://example.com/***"))
        )
    }

    static func facts(_ text: String, urls: [(String, Int)] = []) -> MatchingFacts {
        MatchingFacts(
            text: text,
            addresses: urls.map { .init(kind: .url, span: TextSpan(location: $1, length: $0.utf16.count), value: $0) },
            isSingleAddress: false,
            bundleID: "com.example.Editor",
            canCut: false,
            canPaste: false,
            hasFormatting: false
        )
    }

    // MARK: §8.5 step 4

    @Test func aRegexNarrowsToItsFirstMatchAndKeepsTheCaptures() throws {
        let outcome = ActionMatching.match(Self.action(regex: #"#(\d+)(x)?"#), against: Self.facts("see #42 now"))
        let match = try #require(outcome.match)
        #expect(match.value == "#42")
        #expect(match.regexCaptures == ["#42", "42", nil])
        #expect(match.span == TextSpan(location: 4, length: 3))
        #expect(match.isNarrowed)
    }

    @Test func aRegexThatDoesNotMatchHidesTheAction() {
        #expect(ActionMatching.match(Self.action(regex: #"\d+"#), against: Self.facts("no digits")).refusal == .regexUnmatched)
    }

    @Test func anUnreadableRegexHidesTheActionRatherThanShowingIt() {
        #expect(ActionMatching.match(Self.action(regex: "([a-z"), against: Self.facts("abc")).refusal == .regexUnreadable)
    }

    /// Step 4 runs on what step 3 narrowed to, so a regex over a link sees the link, not the sentence.
    @Test func aRegexRunsOnTheNarrowedValue() throws {
        let text = "go to https://example.com/42 now"
        let outcome = ActionMatching.match(
            Self.action(regex: #"\d+$"#, requirements: ["url"]),
            against: Self.facts(text, urls: [("https://example.com/42", 6)])
        )
        let match = try #require(outcome.match)
        #expect(match.value == "42")
        #expect(match.narrowing == .url)
    }

    // MARK: Round trip

    /// What the builder makes is what the catalog stores; a manifest that does not survive encoding
    /// would lose keys between install and relaunch.
    @Test func aParsedManifestSurvivesEncoding() throws {
        let manifest = try ExtensionLoader.loadSnippet("""
        #popclip
        name: Round Trip
        identifier: com.example.round-trip
        entitlements: [network]
        options:
          - {identifier: loud, type: boolean, label: Loud}
        actions:
          - title: One
            regex: "\\\\w+"
            before: copy
            after: paste-result
            captureHTML: true
            keyCombos: [command c, wait 100]
          - title: Two
            icon: symbol:star
            url: https://example.com/?q=***
            cleanQuery: true
        """).manifest
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
    }
}
