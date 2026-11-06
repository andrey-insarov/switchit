import XCTest
@testable import SwitchitCore

final class WordBufferTests: XCTestCase {
    private var wordKeys: Set<KeyCode> {
        Layout.usEnglish.letterKeys.union(Layout.russian.letterKeys)
    }

    private func type(_ codes: [KeyCode], into buffer: inout WordBuffer) -> [WordBuffer.Event] {
        codes.map { buffer.append(KeyStroke($0)) }
    }

    func testSpaceEndsWord() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        let events = type([.g, .h, .b, .space], into: &buffer)
        XCTAssertEqual(Array(events.dropLast()), [.none, .none, .none])
        XCTAssertEqual(events.last, .word(strokes: [KeyStroke(.g), KeyStroke(.h), KeyStroke(.b)], terminator: .space))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testReturnAndDigitsAreBoundaries() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        XCTAssertEqual(type([.a, .b, .return], into: &buffer).last,
                       .word(strokes: [KeyStroke(.a), KeyStroke(.b)], terminator: .return))
        XCTAssertEqual(type([.a, .b, .one], into: &buffer).last,
                       .word(strokes: [KeyStroke(.a), KeyStroke(.b)], terminator: .one))
    }

    func testBackspaceRemovesLastStroke() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        _ = type([.a, .b, .c, .delete, .delete], into: &buffer)
        XCTAssertEqual(buffer.strokes, [KeyStroke(.a)])
        _ = buffer.append(KeyStroke(.delete))
        _ = buffer.append(KeyStroke(.delete))     // extra backspaces are harmless
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.append(KeyStroke(.space)), .none)
    }

    func testBoundaryWithoutWordReportsNothing() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        XCTAssertEqual(type([.space, .space, .return], into: &buffer), [.none, .none, .none])
        XCTAssertEqual(buffer.flush(), .none)
    }

    func testFlushReportsWordWithoutTerminator() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        _ = type([.o, .k], into: &buffer)
        XCTAssertEqual(buffer.flush(), .word(strokes: [KeyStroke(.o), KeyStroke(.k)], terminator: nil))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEscapeDropsWord() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        XCTAssertEqual(type([.o, .k, .escape], into: &buffer).last, .none)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testShiftIsKept() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        _ = buffer.append(KeyStroke(.h, shift: true))
        _ = buffer.append(KeyStroke(.i))
        XCTAssertEqual(buffer.flush(), .word(strokes: [KeyStroke(.h, shift: true), KeyStroke(.i)], terminator: nil))
    }

    /// A run longer than the limit is not a word: it is dropped, and so is the rest of the run
    /// until the next boundary — the buffer must not report the tail as a fresh short word.
    func testOverlongRunIsDiscardedUntilBoundary() {
        var buffer = WordBuffer(wordKeys: wordKeys, maxLength: 4)
        _ = type([.a, .a, .a, .a, .a, .a, .a], into: &buffer)
        XCTAssertTrue(buffer.strokes.isEmpty)
        XCTAssertEqual(buffer.append(KeyStroke(.space)), .none)
        // After the boundary the buffer works again.
        XCTAssertEqual(type([.o, .k, .space], into: &buffer).last,
                       .word(strokes: [KeyStroke(.o), KeyStroke(.k)], terminator: .space))
    }

    func testRunAtTheLimitIsStillAWord() {
        var buffer = WordBuffer(wordKeys: wordKeys, maxLength: 4)
        let events = type([.a, .b, .c, .d, .space], into: &buffer)
        XCTAssertEqual(events.last, .word(strokes: ([.a, .b, .c, .d] as [KeyCode]).map { KeyStroke($0) }, terminator: .space))
    }

    func testResetDropsSilently() {
        var buffer = WordBuffer(wordKeys: wordKeys)
        _ = type([.a, .b], into: &buffer)
        buffer.reset()
        XCTAssertEqual(buffer.flush(), .none)
    }

    /// Keys outside every layout's letter set — here the ЙЦУКЕН punctuation keys when only
    /// US is enabled — are boundaries, not letters.
    func testWordKeysComeFromTheEnabledLayoutsOnly() {
        var usOnly = WordBuffer(wordKeys: Layout.usEnglish.letterKeys)
        XCTAssertEqual(type([.a, .semicolon], into: &usOnly).last,
                       .word(strokes: [KeyStroke(.a)], terminator: .semicolon))
        var both = WordBuffer(wordKeys: wordKeys)
        XCTAssertEqual(type([.a, .semicolon], into: &both), [.none, .none])
    }
}
