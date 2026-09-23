import Foundation
import PappuCore
import Testing

/// FMT-5: every spelling of a key is the same key.
@Suite struct KeyNormalizerTests {
    @Test(arguments: ["keyName", "key name", "Key Name", "KeyName", "key_name", "key-name", "KEY_NAME", "  key   name "])
    func everySpellingVariantNormalisesToTheSameKey(_ spelling: String) {
        #expect(KeyNormalizer.normalize(spelling) == "key name")
    }

    @Test func aRunOfCapitalsIsOneWord() {
        #expect(KeyNormalizer.normalize("captureHTML") == "capture html")
        #expect(KeyNormalizer.normalize("HTMLCapture") == "html capture")
        #expect(KeyNormalizer.normalize("macOSVersion") == "macos version")
    }

    @Test func aLeadingExtensionOrOptionIsStrippedWhenMoreFollows() {
        #expect(KeyNormalizer.normalize("Extension Identifier") == "identifier")
        #expect(KeyNormalizer.normalize("extensionName") == "name")
        #expect(KeyNormalizer.normalize("Option Label") == "label")
        // Alone, the word is the key.
        #expect(KeyNormalizer.normalize("extension") == "extension")
        #expect(KeyNormalizer.normalize("Option") == "option")
    }

    @Test(arguments: [
        ("AppleScript File", "applescript file"),
        ("Script Interpreter", "interpreter"),
        ("Regular Expression", "regex"),
        ("Blocked Apps", "excluded apps"),
        ("Image File", "icon"),
        ("Required Software Version", "popclip version"),
        ("Required OS Version", "macos version"),
        ("popclipVersion", "popclip version"),
        ("Pass HTML", "capture html"),
        ("flipHorizontal", "flip x"),
        ("preserveImageColor", "preserve color"),
        ("id", "identifier"),
        ("js", "javascript"),
        ("lang", "language"),
        ("params", "parameters"),
    ])
    func theLegacyMapAppliesAfterTheWordRules(_ legacy: String, _ canonical: String) {
        #expect(KeyNormalizer.normalize(legacy) == canonical)
    }

    @Test func aDictionaryKeepsTheFirstOfTwoSpellingsOfOneKey() {
        let dictionary = NormalizedDictionary([
            .init("Title", "first"),
            .init("title", "second"),
        ])
        #expect(dictionary["title"]?.value == .string("first"))
        #expect(dictionary["title"]?.rawKey == "Title")
        #expect(dictionary.keys == ["title"])
    }
}

/// §8.1's decoding: YAML 1.2's core schema, JSON, and property lists, all to one value type.
@Suite struct ConfigDecodingTests {
    static func yaml(_ text: String) throws -> ConfigValue {
        try ConfigDecoding.decodeYAML(text)
    }

    @Test func yesAndNoAreStringsInYAML12() throws {
        #expect(try Self.yaml("a: yes\nb: no\nc: on\nd: true\ne: False") == [
            "a": "yes", "b": "no", "c": "on", "d": true, "e": false,
        ])
    }

    @Test func coreSchemaScalarsAreTyped() throws {
        #expect(try Self.yaml("a: 12\nb: 1.5\nc: null\nd: ~\ne: 0x1F\nf: '12'") == [
            "a": 12, "b": .double(1.5), "c": nil, "d": nil, "e": 31, "f": "12",
        ])
    }

    @Test func keyOrderIsKept() throws {
        guard case .dictionary(let entries) = try Self.yaml("zeta: 1\nalpha: 2\nmid: 3") else {
            Issue.record("not a dictionary")
            return
        }
        #expect(entries.map(\.key) == ["zeta", "alpha", "mid"])
    }

    @Test func aTabIndentIsNamedByLine() {
        #expect(throws: ConfigDecoding.Failure(format: .yaml, reason: .tabIndentation(line: 2))) {
            try Self.yaml("actions:\n\t- title: A")
        }
    }

    @Test func emptyInputIsAnError() {
        #expect(throws: ConfigDecoding.Failure.self) { try ConfigDecoding.decode(Data(), as: .json) }
        #expect(throws: ConfigDecoding.Failure.self) { try ConfigDecoding.decode(Data(), as: .yaml) }
    }

    @Test func jsonIsReadWithItsTypes() throws {
        let value = try ConfigDecoding.decode(Data(#"{"a": true, "b": 1, "c": 1.5, "d": null, "e": ["x"]}"#.utf8), as: .json)
        #expect(value == ["a": true, "b": 1, "c": .double(1.5), "d": nil, "e": ["x"]])
    }

    @Test func jsonIsAlsoYAML() throws {
        #expect(try Self.yaml(#"{"name": "A", "list": [1, 2]}"#) == ["name": "A", "list": [1, 2]])
    }

    @Test func aPlistFalseIsNullAndTrueIsTrue() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>A</string>
        <key>On</key><true/>
        <key>Off</key><false/>
        <key>Count</key><integer>3</integer>
        </dict></plist>
        """
        let value = try ConfigDecoding.decode(Data(plist.utf8), as: .plist)
        guard case .dictionary(let entries) = value else {
            Issue.record("not a dictionary")
            return
        }
        let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        #expect(table["Name"] == "A")
        #expect(table["On"] == true)
        #expect(table["Off"] == .some(.null))
        #expect(table["Count"] == 3)
    }
}
