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
/// `@unchecked Sendable` is sound here because the two mutable fields, `stream` and `retained`, are read and written
/// only inside a `queue.sync` block on this instance's private serial `DispatchQueue`. **That queue is the serialising
/// mechanism**: it is also the queue FSEvents is told to deliver its callback on (`FSEventStreamSetDispatchQueue`), so
/// the callback, `start()` and `stop()` are the only touchers of those fields and they are mutually exclusive by
/// construction. `deinit` is not an exception to that rule, and the next paragraph is why it cannot be.
///
/// A running stream holds a **strong** reference to this object: `start()` puts an
/// `Unmanaged.passRetained(self)` in the FSEvents context and `stop()` releases it. The context's `retain`/`release`
/// callbacks stay nil because that one balanced pair is the whole ownership story. This is what makes the callback's
/// `takeUnretainedValue()` safe: the pointer it resolves is guaranteed live for as long as the stream can call back.
/// It also means `deinit` cannot run while the stream is live — the stream's own reference would still be holding the
/// object up — so `deinit` has no stream to tear down and never touches either field. The cost of that guarantee is
/// that a caller who starts a watcher and drops it without calling `stop()` leaks it rather than crashing; a leak of
/// one object is the right trade against a use-after-free on a pointer an in-flight callback is about to dereference.
///
/// `kFSEventStreamCreateFlagUseCFTypes` is set so the callback's `eventPaths` arrives as a `CFArray` of `CFString`
/// rather than a C array of `char *`, which is what the callback's bridge to `[String]` requires to be sound.
public final class TranscriptWatcher: TranscriptWatching, @unchecked Sendable {
    public let changes: AsyncStream<[URL]>

    private let root: URL
    private let continuation: AsyncStream<[URL]>.Continuation
    private let queue = DispatchQueue(label: "afleet.fleettimeline.transcript-watcher")
    private var stream: FSEventStreamRef?
    /// The `+1` `start()` handed the stream, kept so `stop()` can hand back exactly one.
    private var retained: UnsafeMutableRawPointer?

    public init(configHome: URL) {
        root = configHome.appendingPathComponent("projects", isDirectory: true)
        (changes, continuation) = AsyncStream<[URL]>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Reachable only when the stream is not running, because a running one holds a reference of its own. So there is
    /// nothing to tear down here and, in particular, nothing to read outside `queue`.
    deinit {
        continuation.finish()
    }

    public func start() throws {
        try queue.sync {
            guard stream == nil else { return }
            let info = Unmanaged.passRetained(self).toOpaque()
            var context = FSEventStreamContext(version: 0,
                                               info: info,
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
                Unmanaged<TranscriptWatcher>.fromOpaque(info).release()
                throw TranscriptWatcherError.streamNotCreated
            }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
            retained = info
        }
    }

    /// Runs on `queue`, so an in-flight callback — which runs on that same serial queue — has already returned before
    /// the stream is invalidated and the reference given back. Calling it twice is a no-op, so the `+1` is released once.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            if let retained {
                self.retained = nil
                Unmanaged<TranscriptWatcher>.fromOpaque(retained).release()
            }
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

/// A C function pointer cannot capture, so the watcher travels through `info`. Taking it unretained is safe because
/// `start()` put a `+1` in that pointer which only `stop()` gives back, and `stop()` runs on the same serial queue as
/// this callback: the object cannot be mid-`deinit` here.
private let transcriptWatcherCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.deliver(paths)
}
