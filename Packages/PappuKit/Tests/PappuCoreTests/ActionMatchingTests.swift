import Foundation
import PappuCore
import Testing

/// §8.5's pipeline, step by step (FLT-5).
///
/// Table-driven and exhaustive on purpose: this is the decision a user sees every time the bar
/// appears, and the only way to be sure of it is to run it over every shape the spec names on a
/// machine with no window server, no Accessibility grant and no app in front.
@Suite struct ActionMatchingTests {
    // MARK: Fixtures

    static func action(
        _ requirements: [String] = ["text"],
        requiredApps: [String] = [],
        excludedApps: [String] = []
    ) -> ActionManifest {
        ActionManifest(
            title: "Test",
            requirements: requirements.map(ActionRequirement.init(parsing:)),
            requiredApps: requiredApps,
            excludedApps: excludedApps,
            executor: .builtin(.copy)
        )
    }

    static func facts(
        _ text: String = "hello",
        addresses: [MatchingFacts.Address] = [],
        isSingleAddress: Bool = false,
        bundleID: String? = "com.example.Editor",
        canCut: Bool = false,
        canPaste: Bool = false,
        hasFormatting: Bool = false
    ) -> MatchingFacts {
        MatchingFacts(
            text: text,
            addresses: addresses,
            isSingleAddress: isSingleAddress,
            bundleID: bundleID,
            canCut: canCut,
            canPaste: canPaste,
            hasFormatting: hasFormatting
        )
    }

    static func url(_ value: String, at location: Int = 0) -> MatchingFacts.Address {
        .init(kind: .url, span: TextSpan(location: location, length: value.utf16.count), value: value)
    }

    static func email(_ value: String, at location: Int = 0) -> MatchingFacts.Address {
        .init(kind: .email, span: TextSpan(location: location, length: value.utf16.count), value: value)
    }

    // MARK: Step 1 — app filters

    @Test func anActionWithNoAppRulesShowsAnywhere() {
        #expect(ActionMatching.match(Self.action(), against: Self.facts()).isShown)
    }

    @Test func requiredAppsHidesItEverywhereElse() {
        let action = Self.action(requiredApps: ["com.apple.Safari"])
        #expect(ActionMatching.match(action, against: Self.facts()).refusal == .appNotRequired(bundleID: "com.example.Editor"))
        #expect(ActionMatching.match(action, against: Self.facts(bundleID: "com.apple.Safari")).isShown)
    }

    /// A process with no bundle identifier cannot be on anybody's list, so a restricted action is not
    /// offered there — and an unrestricted one still is.
    @Test func aProcessWithNoBundleIdentifierFailsRequiredAppsAndPassesEverythingElse() {
        #expect(ActionMatching.match(Self.action(requiredApps: ["com.apple.Safari"]), against: Self.facts(bundleID: nil)).refusal
            == .appNotRequired(bundleID: nil))
        #expect(ActionMatching.match(Self.action(), against: Self.facts(bundleID: nil)).isShown)
    }

    @Test func excludedAppsHidesItThere() {
        let action = Self.action(excludedApps: ["com.example.Editor"])
        #expect(ActionMatching.match(action, against: Self.facts()).refusal == .appExcluded(bundleID: "com.example.Editor"))
        #expect(ActionMatching.match(action, against: Self.facts(bundleID: "com.apple.Safari")).isShown)
    }

    /// Bundle identifiers are case-insensitive on macOS, and a manifest author's capitalisation is
    /// not a rule the user should have to know about.
    @Test func bundleIdentifiersMatchWithoutCase() {
        #expect(ActionMatching.match(Self.action(requiredApps: ["COM.EXAMPLE.editor"]), against: Self.facts()).isShown)
    }

    /// A manifest that names one app in both lists contradicts itself. The restrictive reading wins.
    @Test func anAppInBothListsIsExcluded() {
        let action = Self.action(requiredApps: ["com.example.Editor"], excludedApps: ["com.example.Editor"])
        #expect(ActionMatching.match(action, against: Self.facts()).refusal == .appExcluded(bundleID: "com.example.Editor"))
    }

    // MARK: Step 2 — requirements

    @Test func textMeansThereIsASelection() {
        #expect(ActionMatching.match(Self.action(["text"]), against: Self.facts("hi")).isShown)
        #expect(ActionMatching.match(Self.action(["text"]), against: Self.facts("")).refusal
            == .requirementUnmet(ActionRequirement(.text)))
    }

    /// `copy` is PopClip's older spelling of `text`, and an extension written against it must behave
    /// the same here.
    @Test func copyIsTheOlderSpellingOfText() {
        #expect(ActionRequirement(parsing: "copy").condition == .text)
        #expect(ActionMatching.match(Self.action(["copy"]), against: Self.facts("hi")).isShown)
    }

    @Test func httpurlAndHttpurlsAreTheLegacySpellings() {
        #expect(ActionRequirement(parsing: "httpurl").condition == .url)
        #expect(ActionRequirement(parsing: "httpurls").condition == .urls)
    }

    @Test func spellingsAreReadWithoutCase() {
        #expect(ActionRequirement(parsing: "IsURL").condition == .isURL)
        #expect(ActionRequirement(parsing: "  Paste ").condition == .paste)
    }

    @Test func cutAndPasteComeFromTheContext() {
        #expect(ActionMatching.match(Self.action(["cut"]), against: Self.facts(canCut: true)).isShown)
        #expect(ActionMatching.match(Self.action(["cut"]), against: Self.facts(canCut: false)).isShown == false)
        #expect(ActionMatching.match(Self.action(["paste"]), against: Self.facts(canPaste: true)).isShown)
        #expect(ActionMatching.match(Self.action(["paste"]), against: Self.facts(canPaste: false)).isShown == false)
    }

    /// FLT-6 has already been applied to `canPaste` by the time the pipeline sees it, so an action
    /// requiring `paste` is not offered in read-only text even with a caret in it.
    @Test func pasteIsOfferedWithNoSelectionAtAll() {
        #expect(ActionMatching.match(Self.action(["paste"]), against: Self.facts("", canPaste: true)).isShown)
    }

    @Test func formattingComesFromTheControl() {
        #expect(ActionMatching.match(Self.action(["formatting"]), against: Self.facts(hasFormatting: true)).isShown)
        #expect(ActionMatching.match(Self.action(["formatting"]), against: Self.facts()).isShown == false)
    }

    @Test func negationInvertsTheCondition() {
        let requirement = ActionRequirement(parsing: "!formatting")
        #expect(requirement.isNegated)
        #expect(requirement.condition == .formatting)
        #expect(ActionMatching.match(Self.action(["!formatting"]), against: Self.facts()).isShown)
        #expect(ActionMatching.match(Self.action(["!formatting"]), against: Self.facts(hasFormatting: true)).isShown == false)
    }

    @Test func everyRequirementMustHold() {
        let action = Self.action(["text", "cut", "formatting"])
        #expect(ActionMatching.match(action, against: Self.facts(canCut: true, hasFormatting: true)).isShown)
        #expect(ActionMatching.match(action, against: Self.facts(canCut: true)).refusal
            == .requirementUnmet(ActionRequirement(.formatting)))
    }

    /// The refusal names the *first* failure in the author's order, because that is the one a person
    /// reading the manifest would look at first.
    @Test func theRefusalNamesTheFirstRequirementThatFailed() {
        let action = Self.action(["cut", "formatting"])
        #expect(ActionMatching.match(action, against: Self.facts()).refusal == .requirementUnmet(ActionRequirement(.cut)))
    }

    /// The safe half of not knowing: an unknown spelling is never satisfied, and negating it does not
    /// turn it into a condition that always holds.
    @Test func anUnknownRequirementIsNeverSatisfiedEvenNegated() {
        #expect(ActionMatching.match(Self.action(["telepathy"]), against: Self.facts()).refusal == .requirementUnread("telepathy"))
        #expect(ActionMatching.match(Self.action(["!telepathy"]), against: Self.facts()).refusal == .requirementUnread("telepathy"))
    }

    // MARK: Step 2 — option conditions

    @Test func anOptionConditionIsAnsweredByTheExtensionsOwnValues() {
        let action = Self.action(["option-mode=fast"])
        #expect(ActionMatching.match(action, against: Self.facts(), options: ["mode": "fast"]).isShown)
        #expect(ActionMatching.match(action, against: Self.facts(), options: ["mode": "slow"]).isShown == false)
        #expect(ActionMatching.match(action, against: Self.facts()).isShown == false)
    }

    /// PopClip's shorthand: `option-x` with no value means the boolean option is on.
    @Test func anOptionWithNoValueMeansOne() {
        #expect(ActionRequirement(parsing: "option-verbose").condition == .option(id: "verbose", value: "1"))
        #expect(ActionMatching.match(Self.action(["option-verbose"]), against: Self.facts(), options: ["verbose": "1"]).isShown)
    }

    /// Option ids are author-chosen identifiers, and `option-apiKey` is not `option-apikey`.
    @Test func anOptionIdKeepsItsCase() {
        #expect(ActionRequirement(parsing: "option-apiKey=x").condition == .option(id: "apiKey", value: "x"))
    }

    // MARK: Step 3 — narrowing

    @Test func urlNarrowsToTheFirstAddress() {
        let facts = Self.facts(
            "see https://a.example and https://b.example",
            addresses: [Self.url("https://a.example", at: 4), Self.url("https://b.example", at: 26)]
        )
        let match = ActionMatching.match(Self.action(["url"]), against: facts).match
        #expect(match?.narrowing == .url)
        #expect(match?.value == "https://a.example")
        #expect(match?.span == TextSpan(location: 4, length: 17))
    }

    /// §8.5 step 5: whatever step 3 narrowed to, the whole selection is still there for the action
    /// that wants it.
    @Test func theFullTextStaysAvailableAfterNarrowing() {
        let text = "see https://a.example"
        let facts = Self.facts(text, addresses: [Self.url("https://a.example", at: 4)])
        #expect(ActionMatching.match(Self.action(["url"]), against: facts).match?.fullText == text)
    }

    @Test func emailNarrowsToTheFirstEmail() {
        let facts = Self.facts("mail ana@example.com", addresses: [Self.email("ana@example.com", at: 5)])
        let match = ActionMatching.match(Self.action(["email"]), against: facts).match
        #expect(match?.narrowing == .email)
        #expect(match?.value == "ana@example.com")
    }

    /// An action asking for "the addresses" wants all of them; narrowing to the first would be a quiet
    /// way of losing the rest.
    @Test func thePluralFormsDoNotNarrow() {
        let facts = Self.facts(
            "https://a.example https://b.example",
            addresses: [Self.url("https://a.example"), Self.url("https://b.example", at: 18)]
        )
        let match = ActionMatching.match(Self.action(["urls"]), against: facts).match
        #expect(match?.isNarrowed == false)
        #expect(match?.value == facts.text)
    }

    @Test func isurlIsTheWholeSelectionBeingOneAddress() {
        let one = Self.facts("https://a.example", addresses: [Self.url("https://a.example")], isSingleAddress: true)
        #expect(ActionMatching.match(Self.action(["isurl"]), against: one).match?.narrowing == .url)
        let more = Self.facts("see https://a.example", addresses: [Self.url("https://a.example", at: 4)])
        #expect(ActionMatching.match(Self.action(["isurl"]), against: more).isShown == false)
    }

    /// A negated requirement says what is *not* in the selection, so it has nothing to hand the
    /// action: `!url` cannot narrow to a URL that is not there.
    @Test func aNegatedRequirementDoesNotNarrow() {
        let match = ActionMatching.match(Self.action(["text", "!url"]), against: Self.facts("plain")).match
        #expect(match?.isNarrowed == false)
        #expect(match?.value == "plain")
    }

    /// The author's order decides, since two narrowing requirements on one action are a choice
    /// somebody made in a file.
    @Test func theFirstNarrowingRequirementWins() {
        let facts = Self.facts(
            "ana@example.com https://a.example",
            addresses: [Self.email("ana@example.com"), Self.url("https://a.example", at: 16)]
        )
        #expect(ActionMatching.match(Self.action(["url", "email"]), against: facts).match?.narrowing == .url)
        #expect(ActionMatching.match(Self.action(["email", "url"]), against: facts).match?.narrowing == .email)
    }

    @Test func anActionWithNoNarrowingRequirementActsOnTheSelection() {
        let match = ActionMatching.match(Self.action(["text"]), against: Self.facts("hello")).match
        #expect(match?.narrowing == nil)
        #expect(match?.span == nil)
        #expect(match?.value == "hello")
    }

    // MARK: Round-tripping the spelling

    @Test func aRequirementSpellsItselfBackTheWayItIsRead() {
        for spelling in ["text", "cut", "paste", "url", "isurl", "urls", "email", "emails", "path", "formatting",
                         "!text", "!isurl", "option-mode=fast"] {
            #expect(ActionRequirement(parsing: spelling).spelling == spelling, "\(spelling)")
        }
    }

    /// A spelling this build cannot read is kept whole rather than dropped, so that View Source shows
    /// what the author wrote and the registry's diff sees no change where there was none.
    @Test func anUnknownSpellingSurvivesARoundTrip() throws {
        let requirement = ActionRequirement(parsing: "!telepathy")
        #expect(requirement.spelling == "!telepathy")
        let data = try JSONEncoder().encode([requirement])
        #expect(try JSONDecoder().decode([ActionRequirement].self, from: data) == [requirement])
    }
}
