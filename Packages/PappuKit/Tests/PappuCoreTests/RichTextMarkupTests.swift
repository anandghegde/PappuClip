@testable import PappuCore
import Testing

/// JS-7's `RichString`, before AppKit sees it: HTML that can refer to nothing, and Markdown made into
/// such HTML (JS-8, SEC-6).
@Suite struct SafeHTMLTests {
    @Test func whatCanLoadOrRunIsGoneAndItsTextKept() {
        #expect(SafeHTML.clean(#"<p onclick="x()">a<script>bad()</script> <img src="http://t/x.png">b</p>"#) == "<p>a b</p>")
        #expect(SafeHTML.clean(#"<!-- hi --><style>p{background:url(http://t)}</style><b>bold</b>"#) == "<b>bold</b>")
        #expect(SafeHTML.clean(#"<iframe src="https://t"></iframe>after"#) == "after")
        #expect(SafeHTML.clean(#"<link rel="stylesheet" href="http://t/s.css"><div style="background:url(http://t)">x</div>"#) == "<div>x</div>")
    }

    @Test func aLinkKeepsOnlyASafeAddress() {
        #expect(SafeHTML.clean(#"<a href="https://x.test/?a=1&amp;b=2" style="color:red">x</a>"#) == #"<a href="https://x.test/?a=1&amp;b=2">x</a>"#)
        #expect(SafeHTML.clean(#"<a href="javascript:alert(1)">y</a>"#) == "<a>y</a>")
        #expect(SafeHTML.clean("<a href=https://x.test>l</a>") == #"<a href="https://x.test">l</a>"#)
    }

    @Test func markupThatIsNotATagIsText() {
        #expect(SafeHTML.clean("1 < 2 and <3") == "1 &lt; 2 and &lt;3")
        #expect(SafeHTML.clean("open <b") == "open &lt;b")
        #expect(SafeHTML.clean("<B>x</B><br/></br>") == "<b>x</b><br>")
    }
}

@Suite struct MarkdownHTMLTests {
    @Test func headingsParagraphsAndInlineMarkup() {
        #expect(MarkdownHTML.render("# Title\n\nSome **bold** and *it* and `code`.") == "<h1>Title</h1>\n<p>Some <strong>bold</strong> and <em>it</em> and <code>code</code>.</p>")
    }

    @Test func lists() {
        #expect(MarkdownHTML.render("- a\n- b\n\n1. c\n2. d") == "<ul><li>a</li><li>b</li></ul>\n<ol><li>c</li><li>d</li></ol>")
    }

    /// Text is escaped, an image is its alt text, and a link keeps only a safe address — with its
    /// underscores, which are not emphasis.
    @Test func linksImagesAndEscaping() {
        let html = MarkdownHTML.render("[site](https://x.test/a_b_c) <b> ![alt](http://t/i.png) [bad](javascript:x)")
        #expect(html == #"<p><a href="https://x.test/a_b_c">site</a> &lt;b&gt; alt bad</p>"#)
    }

    @Test func codeQuotesAndRules() {
        #expect(MarkdownHTML.render("```\n<x> *y*\n```") == "<pre><code>&lt;x&gt; *y*</code></pre>")
        #expect(MarkdownHTML.render("> quoted **x**") == "<blockquote><p>quoted <strong>x</strong></p></blockquote>")
        #expect(MarkdownHTML.render("a\n\n---\n\nb") == "<p>a</p>\n<hr>\n<p>b</p>")
    }

    /// What it makes is already what `SafeHTML` would keep.
    @Test func itsHTMLIsAlreadySafe() {
        let markdown = "# T\n\n- [a](https://a.test/)\n- **b** `<c>`\n\n> q\n\n```\n<script>\n```"
        let html = MarkdownHTML.render(markdown)
        #expect(SafeHTML.clean(html) == html)
    }
}
