import Foundation
import PappuCore
import Testing

/// §8.4 URL: placeholders, `cleanQuery`, `spacesAsPlus` and ⌥ quoting.
@Suite struct URLTemplateTests {
    private func expand(_ template: String, _ text: String, quoted: Bool = false, clean: Bool = false,
                        plus: Bool = false, options: [String: String] = [:]) -> String? {
        URLTemplate.expand(URLAction(template: template, cleanQuery: clean, spacesAsPlus: plus),
                           text: text, quoted: quoted, options: options)?.absoluteString
    }

    @Test func bothTextPlaceholdersAreTheTrimmedEncodedSelection() {
        #expect(expand("https://x.test/?q=***", "  a b  ") == "https://x.test/?q=a%20b")
        #expect(expand("https://x.test/?q={popclip text}", "a&b=c+d#e") == "https://x.test/?q=a%26b%3Dc%2Bd%23e")
        #expect(expand("https://x.test/?q={PappuClip Text}", "x") == "https://x.test/?q=x")
        #expect(expand("https://x.test/?q=***&again={popclip text}", "é") == "https://x.test/?q=%C3%A9&again=%C3%A9")
    }

    @Test func spacesAsPlusLeavesALiteralPlusEncoded() {
        #expect(expand("https://x.test/?q=***", "a b+c", plus: true) == "https://x.test/?q=a+b%2Bc")
    }

    @Test func cleanQueryMakesOneLine() {
        #expect(expand("https://x.test/?q=***", "one\n\ttwo   three", clean: true) == "https://x.test/?q=one%20two%20three")
        #expect(expand("https://x.test/?q=***", "one\ntwo") == "https://x.test/?q=one%0Atwo")
    }

    @Test func optionQuotesTheQuery() {
        #expect(expand("https://x.test/?q=***", " a b ", quoted: true) == "https://x.test/?q=%22a%20b%22")
    }

    @Test func optionPlaceholdersAreInsertedAsWritten() {
        #expect(expand("https://{popclip option site}/s?k=***", "x", options: ["site": "amazon.co.uk"])
            == "https://amazon.co.uk/s?k=x")
        #expect(expand("https://x.test/{popclip option missing}?q=***", "x") == "https://x.test/?q=x")
        #expect(expand("https://{pappuclip option a}.test/{popclip option b}", "", options: ["a": "one", "b": "two"])
            == "https://one.test/two")
    }

    @Test func aFixedURLOpensAsItStands() {
        #expect(expand("https://x.test/fixed", "ignored") == "https://x.test/fixed")
    }
}
