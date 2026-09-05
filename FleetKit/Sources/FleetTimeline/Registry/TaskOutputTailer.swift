import Foundation

/// One read of a task's output file: the bytes since the last chunk, and the trailer's verdict once it has settled.
public struct OutputChunk: Sendable, Hashable {
    public var text: String
    /// The exit code the engine wrote in the file's final line, once the file has stopped growing. `nil` while the
    /// command is still writing, and on every chunk that is not the last.
    public var exitCode: Int32?
    /// The engine could not write the output to disk and said so in place of the bytes.
    public var truncatedByEngine: Bool
    /// The byte offset in the file at which this chunk's text begins.
    public var offset: Int

    public init(text: String, exitCode: Int32? = nil, truncatedByEngine: Bool = false, offset: Int = 0) {
        self.text = text; self.exitCode = exitCode; self.truncatedByEngine = truncatedByEngine; self.offset = offset
    }
}

/// The engine's last line of a finished task-output file (parity §20.10.5; fixture `background-shell`).
public enum OutputTrailer {
    static let exitPrefix = "exited with code "
    /// What the engine writes instead of the output when the file could not be created.
    public static let omissionNotice = "[output omitted: it could not be written to disk]"

    /// The exit code when `tail` ends with a whole `[exited with code N]` line, and whether the omission notice is
    /// present. The shape is exact on purpose: the same words in the middle of a line are the command's own output,
    /// and reading them as a verdict would end a live tail early.
    public static func parse(_ tail: String) -> (exitCode: Int32?, truncated: Bool) {
        let truncated = tail.contains(omissionNotice)
        var body = Substring(tail)
        if body.hasSuffix("\n") { body = body.dropLast() }
        guard body.hasSuffix("]"), let open = body.lastIndex(of: "[") else { return (nil, truncated) }
        if open != body.startIndex, body[body.index(before: open)] != "\n" { return (nil, truncated) }
        let inner = body[body.index(after: open)..<body.index(before: body.endIndex)]
        guard inner.hasPrefix(exitPrefix) else { return (nil, truncated) }
        guard let code = Int32(inner.dropFirst(exitPrefix.count)) else { return (nil, truncated) }
        return (code, truncated)
    }
}

/// Follows one task's output file and yields what it grows by.
///
/// No Bash output reaches the wire under any flag, so the file is the only place a running shell's output exists; the
/// engine writes it under the system temporary directory, outside the config home, and it may live only seconds. That
/// rules out FSEvents (which watches the config home for transcripts) in favour of `stat` + `pread` polling: the file
/// may not exist yet when the task is announced, and it is unlinked soon after the task ends.
///
/// The file is opened `O_RDONLY | O_NOFOLLOW` and a symlink is refused, for the reason the transcript reader refuses
/// one: a `localAgent` task's output file is a symlink into that agent's transcript sidecar, and a consumer must read
/// that stream through the ingestion rather than tail its bytes.
public actor TaskOutputTailer {
    public let path: URL
    private let pollInterval: Duration
    private let readLimit: Int

    private var offset = 0
    /// Bytes read but held back: a read that ends on the trailer is only believed once a second poll finds the file
    /// unchanged, because a command can print a `]`-terminated line of its own at any moment.
    private var pending = Data()
    private var sawFile = false
    private var finished = false
    private var continuation: AsyncStream<OutputChunk>.Continuation?
    private var pump: Task<Void, Never>?

    /// `readLimit` matches the engine's own 16 MiB cap on a task output file; beyond it the engine stops writing.
    public init(path: URL, pollInterval: Duration = .milliseconds(250), readLimit: Int = 16 * 1024 * 1024) {
        self.path = path
        self.pollInterval = pollInterval
        self.readLimit = readLimit
    }

    /// Starts polling and yields each growth. An absent file is waited for; a file that disappears after it was seen
    /// ends the stream, as does a symlink, a non-regular file, or `stop()`.
    public func chunks() -> AsyncStream<OutputChunk> {
        if let continuation { continuation.finish() }
        let (stream, continuation) = AsyncStream<OutputChunk>.makeStream()
        self.continuation = continuation
        self.finished = false
        let interval = pollInterval
        pump?.cancel()
        pump = Task { [weak self] in
            while true {
                guard let self, await self.poll() else { return }
                do { try await Task.sleep(for: interval) } catch { await self.stop(); return }
            }
        }
        // A consumer that stops iterating — a cancelled task, a closed panel, a `break` — must not leave the pump
        // polling the filesystem for the rest of the tailer's life. Abandoning the stream is a stop.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        return stream
    }

    /// Ends the stream. Every termination path routes through here — an unlinked file, a non-regular or unreadable
    /// one, a cancelled sleep, an abandoned stream, an explicit stop — so the held-back trailer is flushed here and
    /// only here. Dropping it would lose exactly the chunk a consumer waits for: the finished output and its exit
    /// code, in the one poll interval between reading the trailer and confirming it. A finished background shell has
    /// its output file reaped promptly, so that window is not hypothetical.
    public func stop() {
        flushPending()
        finished = true
        continuation?.finish()
        continuation = nil
        pump?.cancel()
        pump = nil
    }

    /// Yield the held-back read. It ends on `]\n` by construction, so its trailer is parsed: the file has stopped
    /// growing, for the most final of reasons.
    private func flushPending() {
        guard !pending.isEmpty, let continuation else { return }
        let buffer = pending
        pending = Data()
        let text = String(decoding: buffer, as: UTF8.self)
        let trailer = OutputTrailer.parse(text)
        continuation.yield(OutputChunk(text: text, exitCode: trailer.exitCode,
                                       truncatedByEngine: trailer.truncated, offset: offset - buffer.count))
    }

    /// Whether the polling task is still alive, and how many bytes are held back awaiting confirmation. Both exist for
    /// the tests: one proves that abandoning a stream stops the pump, the other lets a test open the confirmation
    /// window deterministically instead of racing it.
    var isPolling: Bool { pump != nil }
    var bufferedTrailerBytes: Int { pending.count }

    /// Everything the file holds right now, in one read, with the trailer parsed if it is there. Independent of the
    /// polling offset, so a caller may snapshot a finished file without a stream at all.
    public func snapshot() throws -> OutputChunk {
        try withFile { fd, size in
            let data = try Self.read(fd, from: 0, count: min(size, readLimit))
            let text = String(decoding: data, as: UTF8.self)
            let trailer = OutputTrailer.parse(text)
            return OutputChunk(text: text, exitCode: trailer.exitCode, truncatedByEngine: trailer.truncated, offset: 0)
        }
    }

    // MARK: - Polling

    /// One poll. Returns false when the stream is over.
    private func poll() -> Bool {
        guard !finished else { return false }
        var openErrno: Int32 = 0
        let fd = path.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { openErrno = ENOENT; return -1 }
            let descriptor = open(representation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0 { openErrno = errno }
            return descriptor
        }
        guard fd >= 0 else {
            // Not yet created is not an end; created and then unlinked is.
            if openErrno == ENOENT && !sawFile { return true }
            stop()
            return false
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { stop(); return false }
        sawFile = true

        let size = min(Int(info.st_size), readLimit)
        var fresh = Data()
        if size > offset {
            guard let read = try? Self.read(fd, from: offset, count: size - offset) else { stop(); return false }
            fresh = read
            offset += read.count
        }
        var buffer = pending
        buffer.append(fresh)
        pending = Data()
        guard !buffer.isEmpty else { return true }

        let endsOnTrailer = buffer.suffix(2).elementsEqual([UInt8(ascii: "]"), UInt8(ascii: "\n")])
        if endsOnTrailer && !fresh.isEmpty {
            pending = buffer          // believe it only if the next poll finds the file no longer growing
            return true
        }
        let text = String(decoding: buffer, as: UTF8.self)
        let trailer = OutputTrailer.parse(text)
        continuation?.yield(OutputChunk(text: text,
                                        exitCode: endsOnTrailer ? trailer.exitCode : nil,
                                        truncatedByEngine: trailer.truncated,
                                        offset: offset - buffer.count))
        return true
    }

    // MARK: - File access

    private func withFile<T>(_ body: (Int32, Int) throws -> T) throws -> T {
        var openErrno: Int32 = 0
        let fd = path.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { openErrno = ENOENT; return -1 }
            let descriptor = open(representation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0 { openErrno = errno }
            return descriptor
        }
        guard fd >= 0 else { throw openErrno == ELOOP ? ReaderError.symlinkRefused : ReaderError.unreadable(code: openErrno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReaderError.unreadable(code: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReaderError.notARegularFile }
        return try body(fd, Int(info.st_size))
    }

    private static func read(_ fd: Int32, from offset: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            var read = 0
            var failure: Int32 = 0
            buffer.withUnsafeMutableBytes { raw in
                let n = Foundation.pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset + done))
                if n < 0 { failure = errno } else { read = n }
            }
            if failure != 0 { if failure == EINTR { continue }; throw ReaderError.unreadable(code: failure) }
            if read == 0 { break }
            done += read
        }
        return Data(buffer[0..<done])
    }
}
