@testable import PappuCore
import Testing

/// FLT-4: the selection with how it looks, written as the HTML, RTF and Markdown an extension reads.
@Suite struct StyledTextTests {
    private typealias Run = StyledText.Run

    @Test func aBoldWordInEachForm() {
        let styled = StyledText(runs: [Run(text: "some "), Run(text: "words", bold: true), Run(text: " here")])
        #expect(styled.string == "some words here")
        #expect(styled.html == "<p>some <b>words</b> here</p>")
        #expect(styled.markdown == "some **words** here")
        #expect(styled.rtf == #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}\f0\fs24 {some }{\b words}{ here}}"#)
    }

    /// A line is a paragraph, a break at the very end starts nothing, and the text is escaped for
    /// each form as it is written.
    @Test func paragraphsAndEscaping() {
        let styled = StyledText(runs: [Run(text: "Title\r\n", bold: true, size: 18), Run(text: "Body & <more> \"q\"\n")])
        #expect(styled.html == "<p><b>Title</b></p><p>Body &amp; &lt;more&gt; &quot;q&quot;</p>")
        #expect(styled.markdown == "**Title**\n\nBody & <more> \"q\"")
        #expect(styled.rtf.hasSuffix(#"\fs24 {\b\fs36 Title\par"# + "\n" + #"}{Body & <more> "q"\par"# + "\n}}"))
    }

    /// What the HTML form is made of is what `SafeHTML` keeps, which is why it is the sanitised form
    /// as well as the raw one.
    @Test func theHTMLIsAlreadySafe() {
        let styled = StyledText(runs: [
            Run(text: "<script>x()</script> ", bold: true, italic: true),
            Run(text: "u", underline: true),
            Run(text: "s", strikethrough: true),
        ])
        #expect(styled.html == "<p><b><i>&lt;script&gt;x()&lt;/script&gt; </i></b><u>u</u><s>s</s></p>")
        #expect(SafeHTML.clean(styled.html) == styled.html)
    }

    @Test func markdownEmphasisSitsInsideTheSpaces() {
        #expect(StyledText.markdown(of: Run(text: " bold ", bold: true)) == " **bold** ")
        #expect(StyledText.markdown(of: Run(text: "both", bold: true, italic: true)) == "***both***")
        #expect(StyledText.markdown(of: Run(text: "gone", bold: true, strikethrough: true)) == "**~~gone~~**")
        #expect(StyledText.markdown(of: Run(text: "a*b_c", italic: true)) == #"*a\*b\_c*"#)
        #expect(StyledText.markdown(of: Run(text: "   ", bold: true)) == "   ")
        // Markdown has no underline, so it is left as text.
        #expect(StyledText.markdown(of: Run(text: "under", underline: true)) == "under")
    }

    /// RTF spells anything outside ASCII as UTF-16 units, signed.
    @Test func rtfEscapesBracesAndUnicode() {
        #expect(StyledText.rtfEscaped("café {x} \\ 😀\tend") == #"caf\u233? \{x\} \\ \u-10179?\u-8704?\tab end"#)
    }

    @Test func adjacentRunsThatLookTheSameAreOne() {
        let styled = StyledText(runs: [Run(text: "a", bold: true), Run(text: ""), Run(text: "b", bold: true)])
        #expect(styled.merged == [Run(text: "ab", bold: true)])
        #expect(styled.html == "<p><b>ab</b></p>")
    }

    /// Accessibility names a run's font, and bold and italic are read from the name as a font menu
    /// shows them.
    @Test func boldAndItalicComeFromTheFontsName() {
        func run(_ font: String?) -> Run {
            Run(text: "x", fontName: font, size: 12, underline: false, strikethrough: false)
        }
        #expect(run("Helvetica-BoldOblique") == Run(text: "x", bold: true, italic: true, size: 12))
        #expect(run("Georgia-Italic") == Run(text: "x", italic: true, size: 12))
        #expect(run(".SFNS-Semibold") == Run(text: "x", bold: true, size: 12))
        #expect(run("Menlo-Regular") == Run(text: "x", size: 12))
        #expect(run(nil) == Run(text: "x", size: 12))
    }

    /// FLT-4's last fallback: an app that gives no style still gives the text.
    @Test func plainTextIsStyledTextWithNoStyle() {
        let plain = StyledText(plain: "one\ntwo")
        #expect(plain.string == "one\ntwo")
        #expect(plain.html == "<p>one</p><p>two</p>")
        #expect(plain.markdown == "one\n\ntwo")
        #expect(plain.rtf.hasSuffix(#"\fs24 {one\par"# + "\n" + "two}}"))
    }
}
