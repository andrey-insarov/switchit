import XCTest
@testable import SwitchitCore

/// `BoundedFileReader` is Keepit's reader, copied; these are Keepit's tests for it, copied. Every
/// file the detector loads — the model resources today, exclusion lists and `.switchit` archives
/// later — comes in through it.
final class BoundedReadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let u = dir.appendingPathComponent(name); try data.write(to: u); return u
    }

    func testReadsAFileWithinTheLimitAndRefusesOneBytePast() throws {
        let ok = try file("ok.bin", Data(repeating: 7, count: 1000))
        XCTAssertEqual(try BoundedFileReader.read(ok, max: 1000).count, 1000)
        let big = try file("big.bin", Data(repeating: 7, count: 1001))
        XCTAssertThrowsError(try BoundedFileReader.read(big, max: 1000)) { e in
            XCTAssertEqual(e as? BoundedFileReader.Failure, .tooLarge(limit: 1000))
        }
        XCTAssertEqual(try BoundedFileReader.read(try file("empty.bin", Data()), max: 0).count, 0)
    }

    func testRefusesDirectoriesFifosAndMissingFilesWithoutBlocking() throws {
        XCTAssertThrowsError(try BoundedFileReader.read(dir, max: 1 << 20)) { e in
            XCTAssertEqual(e as? BoundedFileReader.Failure, .notRegularFile)
        }
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try BoundedFileReader.read(fifo, max: 1 << 20)) { e in
            XCTAssertEqual(e as? BoundedFileReader.Failure, .notRegularFile)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a FIFO with no writer must not block the open")
        XCTAssertThrowsError(try BoundedFileReader.read(dir.appendingPathComponent("missing"), max: 10)) { e in
            XCTAssertEqual(e as? BoundedFileReader.Failure, .cannotOpen(ENOENT))
        }
    }

    func testReadsAcrossChunkBoundaries() throws {
        var d = Data(count: (1 << 20) * 3 + 123)
        d.withUnsafeMutableBytes { for i in stride(from: 0, to: $0.count, by: 4097) { $0[i] = UInt8(i % 251) } }
        let u = try file("chunks.bin", d)
        XCTAssertEqual(try BoundedFileReader.read(u, max: d.count), d)
    }
}
