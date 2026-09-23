import Foundation
import PappuCore
import Testing

/// §8.4 Key Press: PopClip's combo format and the legacy dictionary.
@Suite struct KeyComboTests {
    @Test func modifiersAndACharacter() throws {
        #expect(try KeyCombo.parse("command b") == KeyCombo(modifiers: .command, key: .character("b")))
        #expect(try KeyCombo.parse("cmd opt ctrl shift x") == KeyCombo(
            modifiers: [.command, .option, .control, .shift], key: .character("x")
        ))
        #expect(try KeyCombo.parse("  Option   Shift  . ") == KeyCombo(modifiers: [.option, .shift], key: .character(".")))
    }

    @Test func aCapitalLetterIsTheSameKeyAndAddsNoShift() throws {
        #expect(try KeyCombo.parse("command B") == KeyCombo(modifiers: .command, key: .character("b")))
    }

    @Test(arguments: [
        ("return", 0x24), ("space", 0x31), ("delete", 0x33), ("escape", 0x35),
        ("left", 0x7B), ("right", 0x7C), ("down", 0x7D), ("up", 0x7E),
        ("f1", 0x7A), ("F5", 0x60), ("f12", 0x6F), ("f20", 0x5A),
        ("0x74", 0x74), ("0X0", 0x00),
    ] as [(String, Int)])
    func namedAndHexKeys(_ word: String, _ code: Int) throws {
        #expect(try KeyCombo.parse("control \(word)").key == .code(UInt16(code)))
    }

    @Test func numpadChoosesTheKeypadKey() throws {
        #expect(try KeyCombo.parse("option numpad /") == KeyCombo(modifiers: [.option, .numericPad], key: .code(0x4B)))
        #expect(try KeyCombo.parse("numpad 7").key == .code(0x59))
        #expect(try KeyCombo.parse("numpad enter").key == .code(0x4C))
        #expect(throws: KeyCombo.Problem.notOnKeypad("q")) { try KeyCombo.parse("numpad q") }
    }

    @Test func whatCannotBeRead() {
        #expect(throws: KeyCombo.Problem.empty) { try KeyCombo.parse("   ") }
        #expect(throws: KeyCombo.Problem.unknownModifier("hyper")) { try KeyCombo.parse("hyper b") }
        #expect(throws: KeyCombo.Problem.unknownKey("enter")) { try KeyCombo.parse("command enter") }
        #expect(throws: KeyCombo.Problem.unknownKey("0xzz")) { try KeyCombo.parse("0xzz") }
        #expect(throws: KeyCombo.Problem.codeOutOfRange("0x80")) { try KeyCombo.parse("0x80") }
    }

    @Test func theLegacyDictionary() throws {
        #expect(try KeyCombo.legacy(keyCode: 9, keyCharacter: nil, modifiers: 1_048_576)
            == KeyCombo(modifiers: .command, key: .code(9)))
        #expect(try KeyCombo.legacy(keyCode: nil, keyCharacter: "B", modifiers: 1_048_576 + 131_072)
            == KeyCombo(modifiers: [.command, .shift], key: .character("b")))
        #expect(try KeyCombo.legacy(keyCode: 51, keyCharacter: "x", modifiers: 0).key == .code(51))
        #expect(throws: KeyCombo.Problem.self) { try KeyCombo.legacy(keyCode: nil, keyCharacter: "ab", modifiers: 0) }
        #expect(throws: KeyCombo.Problem.self) { try KeyCombo.legacy(keyCode: 200, keyCharacter: nil, modifiers: 0) }
    }

    @Test func theLegacyMaskIsNSEventsFlags() {
        #expect(KeyCombo.Modifiers(legacyMask: 131_072 | 262_144 | 524_288 | 1_048_576) == [.shift, .control, .option, .command])
        #expect(KeyCombo.Modifiers(legacyMask: 0) == [])
    }

    @Test func stepsParseAndWaitsHaveNoCombo() throws {
        #expect(try KeyCombo.parse(KeyPressAction.Step.combo("command v")) == KeyCombo(modifiers: .command, key: .character("v")))
        #expect(try KeyCombo.parse(KeyPressAction.Step.wait(milliseconds: 10)) == nil)
    }

    @Test func theUSLayoutTable() {
        #expect(KeyCombo.ansiKeyCode(for: "v")?.code == 0x09)
        #expect(KeyCombo.ansiKeyCode(for: "v")?.shift == false)
        #expect(KeyCombo.ansiKeyCode(for: "?")?.code == 0x2C)
        #expect(KeyCombo.ansiKeyCode(for: "?")?.shift == true)
        #expect(KeyCombo.ansiKeyCode(for: "é") == nil)
    }
}
