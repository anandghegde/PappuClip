import Foundation
import PappuCore

/// What the analyser is allowed to spend (PRD §11.1: the analysis stage is 20 ms).
///
/// Every field is a ceiling and none of them is a feature: hitting one sets `AnalyzedSelection.bounded`
/// and the bar shows what was found by then. ACT-13's large-selection rule lands on `maxCharacters` and
/// `maxDetections` in M4; they are here now because a 20 ms stage needs them whatever the requirement
/// is called.
public struct AnalysisLimits: Sendable, Equatable, Codable {
    /// How much of the selection is scanned. Past this the text is still the selection in full — it is
    /// only the detectors that stop (§8.5 step 5).
    public var maxCharacters: Int
    public var maxDetections: Int
    /// How many candidate paths may be tested against the disk.
    public var maxFileChecks: Int
    /// How long those tests may take in total. A stat on a stalled network mount blocks for as long as
    /// the mount lets it, so the budget is checked between checks and stops the rest.
    public var fileCheckBudget: Duration

    public init(maxCharacters: Int, maxDetections: Int, maxFileChecks: Int, fileCheckBudget: Duration) {
        self.maxCharacters = maxCharacters
        self.maxDetections = maxDetections
        self.maxFileChecks = maxFileChecks
        self.fileCheckBudget = fileCheckBudget
    }

    /// Provisional, like the rest of §11.1's numbers: 8 ms of the 20 ms stage for the disk, which is
    /// the only part that can block, and the rest for the regular expressions, which cannot.
    public static let initial = AnalysisLimits(
        maxCharacters: 20_000,
        maxDetections: 200,
        maxFileChecks: 32,
        fileCheckBudget: .milliseconds(8)
    )

    private enum CodingKeys: String, CodingKey {
        case maxCharacters, maxDetections, maxFileChecks, fileCheckBudgetMs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxCharacters: try container.decode(Int.self, forKey: .maxCharacters),
            maxDetections: try container.decode(Int.self, forKey: .maxDetections),
            maxFileChecks: try container.decode(Int.self, forKey: .maxFileChecks),
            fileCheckBudget: .milliseconds(try container.decode(Int.self, forKey: .fileCheckBudgetMs))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxCharacters, forKey: .maxCharacters)
        try container.encode(maxDetections, forKey: .maxDetections)
        try container.encode(maxFileChecks, forKey: .maxFileChecks)
        try container.encode(fileCheckBudget.milliseconds, forKey: .fileCheckBudgetMs)
    }
}

/// FLT-2, architecture §6.1: what is in this selection?
///
/// `NSDataDetector` for the addresses and emails the system already knows, plus three detectors of our
/// own for what it does not: a scheme from the bundled list, a scheme-less host whose last label is a
/// real top-level domain, and a path that exists on disk.
///
/// The detectors run in a fixed order and each one may only claim text no earlier detector took, which
/// is what keeps the output non-overlapping. The order is the order of how sure each detector is:
///
/// 1. **`NSDataDetector`.** It has the grammar for `https://…` and `user@host` and we do not.
/// 2. **Bundled schemes.** `omnifocus:///task/1` is unambiguous once the scheme is one we were told about.
/// 3. **File paths.** Before hosts, because `~/notes.md` ends in a real top-level domain and is not a
///    website. A path only counts if it is on this Mac, so claiming early costs nothing.
/// 4. **Scheme-less hosts.** Last, because it is the only detector working from a list of suffixes
///    rather than from a syntax, and so the only one that can be wrong about a plain word.
///
/// A value type with no state of its own, so it is `Sendable` and can be built once and used from
/// anywhere. `analyze` blocks for as long as the disk takes, up to `limits.fileCheckBudget`; callers
/// run it off the main thread, which is where the analysis stage already is.
public struct ContentAnalyzer: Sendable {
    private let schemes: URLSchemes
    private let domains: TopLevelDomains
    private let files: any FileProbing
    private let limits: AnalysisLimits
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameter now: Replaced by tests, as `AttemptClock` does it; see `ManualTimeSource`.
    public init(
        schemes: URLSchemes = .none,
        domains: TopLevelDomains = .none,
        files: any FileProbing = SystemFileProbe(),
        limits: AnalysisLimits = .initial,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.schemes = schemes
        self.domains = domains
        self.files = files
        self.limits = limits
        self.now = now
    }

    /// Reads the two bundled documents and builds an analyser over them.
    ///
    /// Either missing leaves that detector switched off rather than failing the app: an analyser that
    /// finds fewer things still shows a bar, and a bar is what the user pressed for.
    public static func bundled(
        in bundle: Bundle,
        files: any FileProbing = SystemFileProbe(),
        limits: AnalysisLimits = .initial
    ) -> ContentAnalyzer {
        ContentAnalyzer(
            schemes: (try? URLSchemes.bundled(in: bundle)) ?? .none,
            domains: (try? TopLevelDomains.bundled(in: bundle)) ?? .none,
            files: files,
            limits: limits
        )
    }

    public func analyze(_ text: String) -> AnalyzedSelection {
        guard !text.isEmpty else { return AnalyzedSelection(text: text) }

        let length = text.utf16.count
        let window = NSRange(location: 0, length: min(length, limits.maxCharacters))
        var bounded = window.length < length

        var claimed: [Detection] = []
        // Appends only what no earlier detector took, and stops the whole run at the detection cap.
        // Overlap is decided on the span in the text, not on the value, because two detectors can read
        // the same characters as different things — that is the point of the ordering above.
        func claim(_ detection: Detection) {
            guard claimed.count < limits.maxDetections else {
                bounded = true
                return
            }
            guard !claimed.contains(where: { $0.span.overlaps(detection.span) }) else { return }
            claimed.append(detection)
        }

        for detection in systemDetections(in: text, window) { claim(detection) }
        for detection in schemeDetections(in: text, window) { claim(detection) }

        let (paths, ranOutOfBudget) = pathDetections(in: text, window, alreadyClaimed: claimed)
        bounded = bounded || ranOutOfBudget
        for detection in paths { claim(detection) }

        for detection in hostDetections(in: text, window) { claim(detection) }

        claimed.sort { $0.span.location < $1.span.location }
        return AnalyzedSelection(text: text, detections: claimed, bounded: bounded)
    }

    // MARK: 1. What the system already knows

    /// `NSDataDetector` finds `https://…`, `www.…` and `user@host`, and hands every one of them back as
    /// a `URL`, which is how they are told apart here.
    ///
    /// Two normalisations. A bare host comes back as `http://…` and FLT-2 asks for `https://`, so the
    /// scheme is swapped rather than taken as given. And an email arrives as `mailto:`, which is a
    /// scheme the user did not type; the value is the address alone, as `popclip.input.data.emails`
    /// promises.
    ///
    /// What it knows is an older list than IANA's: `example.com` and `site.co.uk` yes, `pappuclip.app`
    /// and `swift.dev` no. That gap is exactly what detector 4 is for.
    private func systemDetections(in text: String, _ window: NSRange) -> [Detection] {
        guard let detector = Self.linkDetector else { return [] }
        var found: [Detection] = []
        detector.enumerateMatches(in: text, options: [], range: window) { match, _, _ in
            guard let match, let url = match.url else { return }
            let span = TextSpan(match.range)
            guard let written = span.substring(of: text) else { return }
            switch url.scheme?.lowercased() {
            case "mailto":
                // `mailto:` written out by the user is still an email address to everything downstream.
                let address = url.absoluteString.hasPrefix("mailto:")
                    ? String(url.absoluteString.dropFirst("mailto:".count))
                    : url.absoluteString
                found.append(Detection(kind: .email, span: span, value: address.removingPercentEncoding ?? address))
            case "http", "https":
                found.append(Detection(kind: .url, span: span, value: Self.httpValue(written: written, url: url)))
            case .some(let scheme) where schemes.contains(scheme):
                found.append(Detection(kind: .nonHTTPURL, span: span, value: written))
            default:
                // A scheme nobody named. Left as text: see `URLSchemes`.
                break
            }
        }
        return found
    }

    /// FLT-2's "normalised by adding `https://`". `NSDataDetector` adds `http://`, and the difference
    /// matters: the normalised value is what Open Link opens.
    ///
    /// The detector's own URL rather than the written text, because for an internationalised host the
    /// two differ: `пример.рф` is written in Cyrillic and reaches `NSWorkspace` as `xn--e1afmkfd.xn--p1ai`.
    /// A scheme the user did type is left exactly as they typed it.
    private static func httpValue(written: String, url: URL) -> String {
        guard !written.lowercased().contains("://") else { return url.absoluteString }
        let absolute = url.absoluteString
        guard absolute.lowercased().hasPrefix("http://") else { return absolute }
        return "https://" + absolute.dropFirst("http://".count)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: 2. A scheme from the bundled list

    /// Everything `NSDataDetector` will not touch because the scheme is an app's rather than the
    /// internet's: `omnifocus:///task/1`, `x-devonthink-item://…`, `message:%3C…%3E`.
    ///
    /// The scheme is checked against `URLSchemes` before anything is claimed, so the pattern being
    /// permissive costs nothing: a scheme that is not on the list is not a detection.
    private func schemeDetections(in text: String, _ window: NSRange) -> [Detection] {
        guard !schemes.schemes.isEmpty, let pattern = Self.schemePattern else { return [] }
        var found: [Detection] = []
        pattern.enumerateMatches(in: text, options: [], range: window) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let scheme = TextSpan(match.range(at: 1)).substring(of: text),
                  schemes.contains(scheme)
            else { return }
            let span = TextSpan(Self.trimmingTrailingPunctuation(match.range, in: text))
            guard let written = span.substring(of: text) else { return }
            found.append(Detection(kind: .nonHTTPURL, span: span, value: written))
        }
        return found
    }

    /// `scheme:` followed by anything that is not whitespace. RFC 3986's scheme grammar for the first
    /// part; deliberately nothing for the second, because an app's URL is whatever that app says it is.
    /// The lookbehind keeps it off the second half of `https://host:8080`.
    private static let schemePattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+.\-/:])([A-Za-z][A-Za-z0-9+.\-]*):[^\s]+"#
    )

    // MARK: 3. A path that is on this Mac

    /// `~/…`, `/…`, `./…` and `../…`, resolved and then checked against the disk (FLT-2).
    ///
    /// Existence is the whole of the rule. It is also the only thing in the analyser that can block, so
    /// the number of checks and the time they take are both capped, and a run that hits either cap
    /// returns what it had and says it was bounded.
    ///
    /// - Returns: The paths found, and whether a cap stopped the search early.
    private func pathDetections(
        in text: String,
        _ window: NSRange,
        alreadyClaimed: [Detection]
    ) -> ([Detection], Bool) {
        guard let pattern = Self.pathPattern else { return ([], false) }
        var found: [Detection] = []
        var checks = 0
        var bounded = false
        let started = now()

        for match in pattern.matches(in: text, options: [], range: window) {
            let span = TextSpan(Self.trimmingTrailingPunctuation(match.range, in: text))
            guard let written = span.substring(of: text) else { continue }
            // A path inside something already claimed — the path part of a `file://` URL, say — is that
            // thing, not a second detection. Checked before the disk so it costs nothing.
            guard !alreadyClaimed.contains(where: { $0.span.overlaps(span) }) else { continue }
            guard checks < limits.maxFileChecks, started.duration(to: now()) < limits.fileCheckBudget else {
                bounded = true
                break
            }
            checks += 1
            let resolved = Self.resolve(written)
            guard files.exists(atPath: resolved) else { continue }
            found.append(Detection(kind: .path, span: span, value: resolved))
        }
        return (found, bounded)
    }

    /// Expands `~` and resolves `..`, which is FLT-2's requirement and also what makes the existence
    /// check meaningful — `stat` follows neither on its own.
    ///
    /// `standardizingPath` is the string operation and not the disk one: it does not resolve symlinks,
    /// so the value stays the path the user selected rather than wherever the Mac keeps it.
    static func resolve(_ path: String) -> String {
        // The shell's escapes, undone: `My\ Notes` is one directory called `My Notes` and that is the
        // name to stat. Only the backslash pair is touched, so a file whose name really does contain a
        // backslash survives as long as it was written escaped, which is how it would have been copied
        // out of a terminal in the first place.
        let unescaped = path.replacingOccurrences(of: #"\ "#, with: " ")
        return (unescaped as NSString).standardizingPath
    }

    /// An absolute, home-relative or dot-relative path, up to the first whitespace.
    ///
    /// Spaces in a path are not supported, and that is a deliberate limit rather than an oversight:
    /// `/Users/me/My Notes/a.txt` is indistinguishable from a path followed by a sentence, and a
    /// detector that guessed would claim the rest of the selection every time it guessed wrong. The
    /// escaped form (`My\ Notes`) is matched, because that one is not a guess.
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?<![^\s"'(\[<])(?:~|\.{1,2})?/(?:\\ |[^\s/])*(?:/(?:\\ |[^\s/])*)*"#
    )

    // MARK: 4. A host with no scheme

    /// `example.com`, `pappuclip.app`, `something.xn--p1ai` — a host whose last label IANA publishes
    /// (FLT-2's "newer TLDs"), normalised with `https://`.
    ///
    /// Last of the four, and the only one that can be wrong about an ordinary word: `.md`, `.sh` and
    /// `.app` are all real top-level domains as well as familiar file extensions. Running after the
    /// path detector is what settles the common case — a file that exists is a file — and the pattern's
    /// lookbehind settles the rest by refusing to start in the middle of a path or an address.
    ///
    /// An internationalised host has to be written in punycode to be found here, because IANA's list is
    /// in punycode and Foundation exposes no way to convert one form to the other. In practice the gap
    /// is small: `NSDataDetector` converts the Cyrillic and Han forms of the established IDN suffixes
    /// itself, so what is missed is a Unicode host under a suffix new enough that the system does not
    /// know it either.
    private func hostDetections(in text: String, _ window: NSRange) -> [Detection] {
        guard domains.count > 0, let pattern = Self.hostPattern else { return [] }
        var found: [Detection] = []
        pattern.enumerateMatches(in: text, options: [], range: window) { match, _, _ in
            guard let match, match.numberOfRanges > 2,
                  let label = TextSpan(match.range(at: 2)).substring(of: text),
                  domains.contains(label)
            else { return }
            let span = TextSpan(Self.trimmingTrailingPunctuation(match.range, in: text))
            guard let written = span.substring(of: text) else { return }
            found.append(Detection(kind: .url, span: span, value: "https://" + written))
        }
        return found
    }

    /// Dot-separated labels, a path and a query allowed after them, with the last label captured so it
    /// can be looked up. The lookbehind refuses to start after a character that means this is part of
    /// something else: `@` (an email's host), `/` or `.` (inside a path or a longer host), and the
    /// letters and digits that would mean starting mid-word.
    ///
    /// The lookahead after the captured suffix is what stops the match ending in the middle of a label:
    /// without it `foo.commercial` offers `com` to the list and becomes a link. The punycode branch
    /// comes first for the same reason — `xn--p1ai` begins with two letters that are a suffix of their
    /// own.
    private static let hostPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9@._/\-])((?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?\.)+(xn--[A-Za-z0-9\-]{2,59}|[A-Za-z]{2,63}))(?![A-Za-z0-9\-])(?::\d{1,5})?(?:/[^\s]*)?"#
    )

    // MARK: Shared

    /// Drops the punctuation a sentence puts after an address: `see example.com.` is not a host called
    /// `com.`, and `(example.com)` is not one with a bracket on the end. Brackets are only dropped when
    /// they are unbalanced, because a Wikipedia URL ends in a real one.
    static func trimmingTrailingPunctuation(_ range: NSRange, in text: String) -> NSRange {
        var range = range
        while range.length > 0, let last = TextSpan(location: range.location + range.length - 1, length: 1).substring(of: text) {
            guard let scalar = last.unicodeScalars.first else { break }
            let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", "»", "”", "’"]
            if trailing.contains(Character(scalar)) {
                range.length -= 1
                continue
            }
            if last == ")" || last == "]" || last == ">" {
                let opening: Character = last == ")" ? "(" : (last == "]" ? "[" : "<")
                let closing = Character(last)
                let body = TextSpan(range).substring(of: text) ?? ""
                if body.filter({ $0 == opening }).count < body.filter({ $0 == closing }).count {
                    range.length -= 1
                    continue
                }
            }
            break
        }
        return range
    }
}

extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
