import PappuCore
import Testing

/// §8.9's defaults, applied once for the matcher, the runners and the settings sheet alike.
@Suite struct OptionValuesTests {
    static let options: [OptionManifest] = [
        OptionManifest(identifier: nil, kind: .heading, label: "Section"),
        OptionManifest(identifier: "name", kind: .string),
        OptionManifest(identifier: "loud", kind: .boolean),
        OptionManifest(identifier: "quiet", kind: .boolean, defaultValue: .boolean(false)),
        OptionManifest(identifier: "engine", kind: .multiple, values: ["google", "bing"]),
        OptionManifest(identifier: "site", kind: .string, defaultValue: .string("example.com")),
        OptionManifest(identifier: "token", kind: .secret),
        OptionManifest(identifier: "pass", kind: .password),
    ]

    @Test func unsetOptionsTakeTheSpecsDefaults() {
        let values = OptionValues.effective(Self.options, stored: [:])
        #expect(values == [
            "name": "", "loud": "1", "quiet": "0", "engine": "google", "site": "example.com", "token": "", "pass": "",
        ])
    }

    @Test func storedValuesWinAndBooleansAreOneOrZero() {
        let values = OptionValues.effective(Self.options, stored: ["name": "Ann", "loud": "false", "engine": "bing"])
        #expect(values["name"] == "Ann")
        #expect(values["loud"] == "0")
        #expect(values["engine"] == "bing")
    }

    /// A secret comes from the Keychain, never from the store's rows.
    @Test func aSecretIsReadOnlyFromSecrets() {
        #expect(OptionValues.effective(Self.options, stored: ["token": "leaked"])["token"] == "")
        #expect(OptionValues.effective(Self.options, stored: [:], secrets: ["token": "s3"])["token"] == "s3")
    }

    /// FLT-5: an `option-loud=1` requirement matches an unset boolean, as it does in PopClip.
    @Test func aRequirementSeesTheDefault() {
        let values = OptionValues.effective(Self.options, stored: [:])
        #expect(values["loud"] == OptionValues.on)
    }
}
