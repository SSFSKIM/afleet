import Foundation

public enum ReaderError: Error, Sendable, Equatable { case notARegularFile, symlinkRefused, unreadable(code: Int32) }

/// Where one record's bytes lie in its file. The reader is stream-less, so this is offset and length only; Task 4's
/// `RecordLocator` is a `ByteRange` plus the stream the ingestion knows.
public struct ByteRange: Sendable, Hashable, Codable {
    public var offset: Int
    public var length: Int
    public init(offset: Int, length: Int) { self.offset = offset; self.length = length }
}
public struct ReadResult: Sendable {
    public var records: [TranscriptRecord]
    public var ranges: [ByteRange]         // parallel to `records`: each record's bytes, for `read(at:length:)`
    public var length: Int                 // the byte length the read covered, i.e. the next `readAppended(from:)` offset
    public var window: WindowMarker?
    public init(records: [TranscriptRecord], ranges: [ByteRange], length: Int, window: WindowMarker? = nil) { self.records = records; self.ranges = ranges; self.length = length; self.window = window }
}
public struct WindowMarker: Sendable, Hashable, Codable {
    public var earlierAvailable: Bool
    public var continueBefore: Int          // byte offset at which `readEarlier(before:)` continues
    public init(earlierAvailable: Bool, continueBefore: Int) { self.earlierAvailable = earlierAvailable; self.continueBefore = continueBefore }
}
public struct WindowPolicy: Sendable, Hashable {
    public var wholeFileUpTo: Int          // above the local p99 (spec Grounding)
    public var initialTail: Int
    public var earlierStep: Int
    /// Declared memberwise with defaults: a declared `init()` suppresses the synthesised memberwise initialiser, and `.whole`
    /// and the tests' policies would not compile. `.init()` still means the defaults.
    public init(wholeFileUpTo: Int = 8 * 1024 * 1024, initialTail: Int = 4 * 1024 * 1024, earlierStep: Int = 4 * 1024 * 1024) { self.wholeFileUpTo = wholeFileUpTo; self.initialTail = initialTail; self.earlierStep = earlierStep }
    public static let whole = WindowPolicy(wholeFileUpTo: .max, initialTail: .max, earlierStep: .max)
}

/// One transcript file, opened `O_RDONLY | O_NOFOLLOW` on every call; a symlink or a non-regular file is refused.
public struct TranscriptReader: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    // MARK: - Reads

    /// Whole file. The partial tail — bytes after the last `\n` — is held back, so `length` is where the next append starts.
    public func readAll() throws -> ReadResult {
        try withFile { fd, size in
            let scanned = try materialise(fd, from: 0, to: size)
            return ReadResult(records: scanned.records, ranges: scanned.ranges, length: scanned.end,
                              window: WindowMarker(earlierAvailable: false, continueBefore: 0))
        }
    }

    /// The bytes after `offset`. An `offset` beyond the file's end yields nothing and the file's length: the caller
    /// (Task 10's rewrite arm) is the one that decides a shorter file is a rewrite.
    public func readAppended(from offset: Int) throws -> ReadResult {
        try withFile { fd, size in
            guard offset < size else { return ReadResult(records: [], ranges: [], length: min(offset, size)) }
            let scanned = try materialise(fd, from: offset, to: size)
            return ReadResult(records: scanned.records, ranges: scanned.ranges, length: scanned.end)
        }
    }

    /// The whole file when it is at or under `policy.wholeFileUpTo`; otherwise the last `policy.initialTail` bytes,
    /// aligned forward to a line start, with a marker saying earlier bytes remain.
    public func readWindow(policy: WindowPolicy = .init()) throws -> ReadResult {
        try withFile { fd, size in
            let from = (policy.initialTail >= size) ? 0 : size - policy.initialTail
            if size <= policy.wholeFileUpTo || from == 0 {
                let scanned = try materialise(fd, from: 0, to: size)
                return ReadResult(records: scanned.records, ranges: scanned.ranges, length: scanned.end,
                                  window: WindowMarker(earlierAvailable: false, continueBefore: 0))
            }
            // The byte before `from` decides whether `from` is itself a line start, so the probe starts one byte earlier.
            let lineStart = try firstLineStart(fd, from: from, before: size) ?? size
            let scanned = try materialise(fd, from: lineStart, to: size)
            return ReadResult(records: scanned.records, ranges: scanned.ranges, length: scanned.end,
                              window: WindowMarker(earlierAvailable: true, continueBefore: lineStart))
        }
    }

    /// One `policy.earlierStep` back from `before` (which must be a line start), aligned forward to a line start.
    /// `earlierAvailable` is false exactly when the step reached offset 0. `length` is `before`: the caller keeps
    /// its own append offset, which lies at the other end of the file.
    public func readEarlier(before offset: Int, policy: WindowPolicy = .init()) throws -> ReadResult {
        try withFile { fd, size in
            let before = min(offset, size)
            guard before > 0 else {
                return ReadResult(records: [], ranges: [], length: 0, window: WindowMarker(earlierAvailable: false, continueBefore: 0))
            }
            var step = max(1, policy.earlierStep)
            var lineStart = 0
            var earlierAvailable = false
            while true {
                if step >= before { lineStart = 0; earlierAvailable = false; break }
                if let candidate = try firstLineStart(fd, from: before - step, before: before), candidate < before {
                    lineStart = candidate; earlierAvailable = true; break
                }
                // No line start inside this step: one record is longer than the step. Doubling keeps the walk
                // monotone — it never republishes a torn line — and terminates at offset 0.
                step = min(before, step * 2)
            }
            let scanned = try materialise(fd, from: lineStart, to: before)
            return ReadResult(records: scanned.records, ranges: scanned.ranges, length: before,
                              window: WindowMarker(earlierAvailable: earlierAvailable, continueBefore: lineStart))
        }
    }

    /// One record's bytes, addressed by the `ByteRange` a read reported. For `StreamIngestion.rawRecord(for:)`.
    public func read(at offset: Int, length: Int) throws -> Data {
        try withFile { fd, size in
            guard offset >= 0, offset <= size else { return Data() }
            return try pread(fd, offset: offset, length: min(length, size - offset))
        }
    }

    public func byteLength() throws -> Int { try withFile { _, size in size } }

    // MARK: - Bytes

    /// `open(2)` with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, then `fstat`: anything that is not a regular file is refused,
    /// and the `ELOOP` a symlink raises is named as such. The descriptor is closed on every exit.
    private func withFile<T>(_ body: (Int32, Int) throws -> T) throws -> T {
        var openErrno: Int32 = 0
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { openErrno = ENOENT; return -1 }
            let d = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if d < 0 { openErrno = errno }
            return d
        }
        guard fd >= 0 else { throw openErrno == ELOOP ? ReaderError.symlinkRefused : ReaderError.unreadable(code: openErrno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReaderError.unreadable(code: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReaderError.notARegularFile }
        return try body(fd, Int(info.st_size))
    }

    /// The storage is left uninitialised until `pread` fills it and the result is the buffer itself, not a copy of it: a
    /// window read is four mebibytes, and zeroing it and then copying it were both plainly on the channel-open path.
    private func pread(_ fd: Int32, offset: Int, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        var done = 0
        var failure: Int32 = 0
        var buffer = [UInt8](unsafeUninitializedCapacity: length) { storage, count in
            while done < length {
                let n = Foundation.pread(fd, storage.baseAddress! + done, length - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; failure = errno; break }
                if n == 0 { break }
                done += n
            }
            count = done
        }
        if failure != 0 { throw ReaderError.unreadable(code: failure) }
        if buffer.count > done { buffer.removeLast(buffer.count - done) }
        return Data(buffer)
    }

    /// The smallest line start at or after `from` and strictly inside `[from, before)` bounds, or nil when the region
    /// carries no terminator. Reading from `from - 1` is what makes `from` itself count when the byte before it is `\n`.
    private func firstLineStart(_ fd: Int32, from: Int, before: Int) throws -> Int? {
        // In chunks, doubling: the answer is almost always in the first few kilobytes, and reading the whole region to
        // find one byte meant a window read `pread`-ed and scanned its four mebibytes twice.
        let probe = max(0, from - 1)
        var at = probe
        var chunk = 64 * 1024
        while at < before {
            let data = try pread(fd, offset: at, length: min(chunk, before - at))
            if data.isEmpty { return nil }
            if let nl = data.firstIndex(of: UInt8(ascii: "\n")) { return at + (nl - data.startIndex) + 1 }
            at += data.count
            chunk = min(chunk * 2, 4 * 1024 * 1024)
        }
        return nil
    }

    /// Decode `[from, to)`. The scanner reports each line's raw start and its bytes after the engine's leading-whitespace
    /// skip; the skip is re-walked here so a `ByteRange` addresses exactly the bytes that were decoded.
    private func materialise(_ fd: Int32, from: Int, to: Int) throws -> (records: [TranscriptRecord], ranges: [ByteRange], end: Int) {
        let data = try pread(fd, offset: from, length: to - from)
        let scan = LineScanner.scan(data, base: from)
        var records: [TranscriptRecord] = []; var ranges: [ByteRange] = []
        records.reserveCapacity(scan.lines.count); ranges.reserveCapacity(scan.lines.count)
        for line in scan.lines {
            var start = line.offset
            var index = data.index(data.startIndex, offsetBy: start - from)
            while index < data.endIndex, data[index] <= 32 { index = data.index(after: index); start += 1 }
            records.append(RecordDecoder.decode(line: line.bytes, byteOffset: start))
            ranges.append(ByteRange(offset: start, length: line.bytes.count))
        }
        return (records, ranges, from + scan.consumed)
    }
}
