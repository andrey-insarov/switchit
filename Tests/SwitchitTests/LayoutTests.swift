import XCTest
@testable import SwitchitCore

final class LayoutTests: XCTestCase {
    /// `ghbdtn` typed on a US keyboard is `привет` under the Russian layout.
    func testSameKeysReadUnderBothLayouts() {
        let keys = ([.g, .h, .b, .d, .t, .n] as [KeyCode]).map { KeyStroke($0) }
        XCTAssertEqual(Layout.usEnglish.text(for: keys), "ghbdtn")
        XCTAssertEqual(Layout.russian.text(for: keys), "привет")
        XCTAssertEqual(Layout.russianPC.text(for: keys), "привет")
    }

    func testShiftUppercases() {
        let keys = [KeyStroke(.h, shift: true), KeyStroke(.e), KeyStroke(.l), KeyStroke(.l), KeyStroke(.o)]
        XCTAssertEqual(Layout.usEnglish.text(for: keys), "Hello")
        XCTAssertEqual(Layout.russian.text(for: keys), "Руддщ")
    }

    /// The punctuation keys that carry Russian letters are letters there and nothing in US.
    func testPunctuationKeysCarryLettersOnlyInRussian() {
        let keys = [KeyStroke(.leftBracket), KeyStroke(.semicolon), KeyStroke(.quote), KeyStroke(.comma)]
        XCTAssertNil(Layout.usEnglish.text(for: keys))
        XCTAssertEqual(Layout.russian.text(for: keys), "хжэб")
    }

    func testYoSitsOnDifferentKeysInTheTwoRussianLayouts() {
        XCTAssertEqual(Layout.russian.character(for: KeyStroke(.backslash)), "ё")
        XCTAssertNil(Layout.russian.character(for: KeyStroke(.grave)))
        XCTAssertEqual(Layout.russianPC.character(for: KeyStroke(.grave)), "ё")
        XCTAssertNil(Layout.russianPC.character(for: KeyStroke(.backslash)))
        XCTAssertEqual(Layout.russianPC.character(for: KeyStroke(.grave, shift: true)), "Ё")
    }

    func testNonLetterKeysAreNotLetters() {
        for layout in Layout.builtIn {
            XCTAssertNil(layout.character(for: KeyStroke(.space)), layout.id)
            XCTAssertNil(layout.character(for: KeyStroke(.one)), layout.id)
            XCTAssertNil(layout.character(for: KeyStroke(.delete)), layout.id)
            XCTAssertNil(layout.text(for: [KeyStroke(.a), KeyStroke(.space)]), layout.id)
        }
    }

    func testLetterCounts() {
        XCTAssertEqual(Layout.usEnglish.letterKeys.count, 26)
        XCTAssertEqual(Layout.russian.letterKeys.count, 33)
        XCTAssertEqual(Layout.russianPC.letterKeys.count, 33)
        // Every alphabet letter appears exactly once per layout.
        for layout in Layout.builtIn {
            let letters = layout.letterKeys.compactMap { layout.character(for: KeyStroke($0)) }
            XCTAssertEqual(Set(letters).count, letters.count, layout.id)
        }
    }

    func testIdsAreDistinct() {
        XCTAssertEqual(Set(Layout.builtIn.map(\.id)).count, Layout.builtIn.count)
    }
}
