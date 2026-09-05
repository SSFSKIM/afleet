import Foundation
import CoreServices
import ClaudeWire

/// What the app hands the index: batches of paths that changed under `projects/`. The index and the ingestion take
/// their changes through `update(changed:)` and `fileChanged(_:)` alone, so every test drives them without FSEvents.
public protocol TranscriptWatching: Sendable {
    var changes: AsyncStream<[URL]> { get }
    func start() throws
    func stop()
}

public enum TranscriptWatcherError: Error, Sendable {
    /// `FSEventStreamCreate` returned null — the path is unwatchable.
    case streamNotCreated
}

/// FSEvents over `<configHome>/projects`, with `kFSEventStreamCreateFlagFileEvents` and
/// `kFSEventStreamCreateFlagNoDefer` at 0.1 s latency. Paths are coalesced per callback batch and delivered as one
/// array; a directory event delivers the directory URL, which is why the index does not attempt discovery of its own
/// and the app passes the directory's new files.
///
/// `@unchecked Sendable` is sound here because the one mutable field is `stream`, and every read and every write of it
/// happens inside a `queue.sync` block on this instance's private serial `DispatchQueue`. **That queue is the
/// serialising mechanism**: it is also the queue FSEvents is told to deliver its callback on
/// (`FSEventStreamSetDispatchQueue`), so the callback, `start()` and `stop()` are the only touchers of the field and
/// they are mutually exclusive by construction. `kFSEventStreamCreateFlagUseCFTypes` is set so the callback's
/// `eventPaths` arrives as a `CFArray` of `CFString` rather than a C array of `char *`.
public final class TranscriptWatcher: TranscriptWatching, @unchecked Sendable {
    public let changes: AsyncStream<[URL]>

    private let root: URL
    private let continuation: AsyncStream<[URL]>.Continuation
    private let queue = DispatchQueue(label: "afleet.fleettimeline.transcript-watcher")
    private var stream: FSEventStreamRef?

    public init(configHome: URL) {
        root = configHome.appendingPathComponent("projects", isDirectory: true)
        (changes, continuation) = AsyncStream<[URL]>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation.finish()
    }

    public func start() throws {
        try queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0,
                                               info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                                    transcriptWatcherCallback,
                                                    &context,
                                                    [root.path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                    0.1,
                                                    flags) else {
                throw TranscriptWatcherError.streamNotCreated
            }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Called on `queue` from the FSEvents callback. One batch of paths becomes one array, duplicates removed and the
    /// callback's order kept.
    fileprivate func deliver(_ paths: [String]) {
        var seen: Set<String> = []
        var urls: [URL] = []
        for path in paths where seen.insert(path).inserted { urls.append(URL(fileURLWithPath: path)) }
        guard !urls.isEmpty else { return }
        continuation.yield(urls)
    }
}

/// A C function pointer cannot capture, so the watcher travels through `info` and comes back unretained — it owns the
/// stream and outlives every callback the stream delivers.
private let transcriptWatcherCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.deliver(paths)
}
