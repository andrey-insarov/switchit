// From Keepit (Sources/Keepit/Core/BoundedFileReader.swift), same author, MIT — copied, not shared.
import Foundation

/// The one way Switchit reads a file whose size it does not control: open the descriptor, check that
/// it is a regular file, read at most `max` bytes — and refuse at `max + 1`, counting what was really
/// read rather than trusting a size stat that can change between the stat and the read.
///
/// `Data(contentsOf:)` reads whatever is there into memory first and lets the caller check the size
/// afterwards; a FIFO or device blocks it; a file that grows after the stat passes a stat-only check.
/// Every external file — a backup, a file chosen in the Viewer, another program's export — and every
/// file of our own whose size we did not just write comes through here.
enum BoundedFileReader {
    enum Failure: Error, Equatable {
        case cannotOpen(Int32)       // errno
        case notRegularFile
        case tooLarge(limit: Int)
        case readFailed(Int32)
    }

    /// Reads `url` into memory if it is a regular file of at most `max` bytes.
    /// Symbolic links are followed (the user may well pick an alias); what is opened must be a regular file.
    static func read(_ url: URL, max: Int) throws -> Data {
        precondition(max >= 0)
        // O_NONBLOCK: opening a FIFO or a character device must not hang before fstat can refuse it.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.cannotOpen(errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure.readFailed(errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegularFile }
        // A size over the limit is refused before the first byte; a size under it is still re-counted.
        if st.st_size > Int64(max) { throw Failure.tooLarge(limit: max) }
        // Regular files never block; clear the flag so a slow volume reads normally.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)

        var out = Data()
        out.reserveCapacity(Int(min(st.st_size, Int64(max))))
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let want = min(chunk, max + 1 - out.count)      // one byte past the limit is enough to know
            if want == 0 { throw Failure.tooLarge(limit: max) }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.readFailed(errno)
            }
            if n == 0 { break }
            buffer.withUnsafeBufferPointer { out.append($0.baseAddress!, count: n) }
            if out.count > max { throw Failure.tooLarge(limit: max) }
        }
        return out
    }
}
