import AppKit
import CoreServices
import Foundation
import PappuCore

/// The system behind the host API's seam (JS-4, JS-6, JS-7): the Finder, the sharing services, Dictionary
/// Services, the spell checker and AppKit's rich text. Each is used on the main actor, which is where
/// AppKit wants them.
public struct SystemHostServices: HostServices {
    public init() {}

    /// A file is selected in its folder; a folder is opened as the window's own root.
    public func reveal(_ url: URL) async -> Bool {
        await MainActor.run {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            if isDirectory.boolValue {
                return NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
    }

    /// Hands the items to the named service. The share's own window, when it has one, is the service's
    /// and can stay open as long as the user likes, so this answers once the service has the items rather
    /// than when the user is done with it.
    public func share(_ items: [HostShareItem], with service: String) async -> String? {
        var forms: [Int: RichTextForms] = [:]
        for (index, item) in items.enumerated() {
            if case .rich(let source, let format) = item {
                guard let converted = await convert(source, from: format) else { return "An item could not be read as \(format.rawValue)." }
                forms[index] = converted
            }
        }
        let prepared = forms
        return await MainActor.run { () -> String? in
            guard let sharing = NSSharingService(named: NSSharingService.Name(service)) else {
                return "There is no sharing service called \(service)."
            }
            var objects: [Any] = []
            for (index, item) in items.enumerated() {
                switch item {
                case .text(let text): objects.append(text as NSString)
                case .url(let url): objects.append(url as NSURL)
                case .rich:
                    guard let forms = prepared[index], let attributed = Self.attributed(rtf: forms.rtf) else {
                        return "An item could not be shared."
                    }
                    objects.append(attributed)
                }
            }
            guard sharing.canPerform(withItems: objects) else { return "\(service) cannot share these items." }
            sharing.perform(withItems: objects)
            return nil
        }
    }

    /// Dictionary Services' definition, when the text as a whole is a term.
    public func definition(of text: String) async -> String? {
        let length = CFIndex((text as NSString).length)
        guard length > 0 else { return nil }
        let term = DCSGetTermRangeInString(nil, text as CFString, 0)
        guard term.location == 0, term.length == length else { return nil }
        guard let definition = DCSCopyTextDefinition(nil, text as CFString, CFRange(location: 0, length: length))?.takeRetainedValue() else {
            return nil
        }
        return definition as String
    }

    public func spellingLanguages() async -> [SpellingLanguage] {
        await MainActor.run {
            NSSpellChecker.shared.availableLanguages.map { code in
                SpellingLanguage(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code)
            }
        }
    }

    public func preferredSpellingLanguages() async -> [String] {
        await MainActor.run {
            let available = Set(NSSpellChecker.shared.availableLanguages)
            return NSSpellChecker.shared.userPreferredLanguages.filter(available.contains)
        }
    }

    public func checkSpelling(_ text: String, language: String) async -> Bool? {
        await MainActor.run {
            let checker = NSSpellChecker.shared
            guard checker.availableLanguages.contains(language) else { return nil }
            let found = checker.checkSpelling(of: text, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            return found.location == NSNotFound
        }
    }

    /// Guesses only when the whole text, less surrounding space, is one misspelled word.
    public func spellingGuesses(for text: String, language: String, limit: Int?) async -> [String]? {
        await MainActor.run {
            let checker = NSSpellChecker.shared
            guard checker.availableLanguages.contains(language) else { return nil }
            let found = checker.checkSpelling(of: text, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            let word = (text as NSString).range(of: text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard found.location != NSNotFound, found == word else { return [] }
            let guesses = checker.guesses(forWordRange: found, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
            return limit.map { Array(guesses.prefix($0)) } ?? guesses
        }
    }

    /// RTF is read as it is. HTML is first reduced to formatting by `SafeHTML`, and Markdown is made into
    /// HTML by `MarkdownHTML`, which is safe by construction: AppKit reads HTML with WebKit, and nothing a
    /// script wrote may make it fetch anything (JS-8, SEC-6).
    public func convert(_ source: String, from format: RichTextFormat) async -> RichTextForms? {
        let html: String? = switch format {
        case .rtf: nil
        case .html: SafeHTML.clean(source)
        case .markdown: MarkdownHTML.render(source)
        }
        return await MainActor.run {
            let attributed: NSAttributedString? = if let html { Self.attributed(html: html) } else { Self.attributed(rtf: source) }
            guard let attributed else { return nil }
            let range = NSRange(location: 0, length: attributed.length)
            guard let rtf = attributed.rtf(from: range, documentAttributes: [:]),
                  let exported = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
            else { return nil }
            return RichTextForms(rtf: String(decoding: rtf, as: UTF8.self), html: String(decoding: exported, as: UTF8.self))
        }
    }

    @MainActor
    static func attributed(rtf: String) -> NSAttributedString? {
        NSAttributedString(rtf: Data(rtf.utf8), documentAttributes: nil)
    }

    @MainActor
    static func attributed(html: String) -> NSAttributedString? {
        NSAttributedString(
            html: Data(html.utf8),
            options: [.characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }
}
