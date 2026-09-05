import Foundation
import CryptoKit
import ClaudeWire

/// One channel's ingestion: every stream of one logical session, fed from two sources that both deliver the same
/// records — the transcript files on disk and the engine's `transcript_mirror` frames on the wire — reconciled into one
/// idempotent apply path (spec "Source arbitration (`Ingest/StreamIngestion`)"; parent §7.3).
///
/// The actor owns the ordering between the channel's tap and the file: `open` starts consuming the tap into a buffer,
/// reads the file, waits for the tap to fall quiet, aligns the buffered mirror entries against the read's tail and only
/// then applies what the alignment did not claim. From then on each source confirms the other: a mirror entry the file
/// already holds is a counted duplicate, a file line a mirror entry already delivered binds that record's locator, and
/// a record that only one side ever delivers is still applied exactly once.
public actor StreamIngestion {

    // MARK: - Public vocabulary

    /// The parent's build flag. It decides one thing here: whether a record the watcher applied and no mirror frame
    /// confirmed is a fault (`mirrorPrimary`) or nothing at all (`filePrimary`). Both modes run the same apply path.
    public enum Mode: Sendable { case filePrimary, mirrorPrimary }

    /// `mirrorOnly`: opened on a main path that does not exist yet — the mirror is the only source until the first
    /// `fileChanged` finds the file.
    public enum State: Sendable, Hashable { case both, fileOnly(since: ProcessEpoch), mirrorOnly }

    public struct Effect: Sendable {
        public var applied: [RecordKey]
        public var duplicates: Int
        public var routedElsewhere: Int
        public var changes: [TimelineChange]
        public var stateChange: State?
        public init(applied: [RecordKey] = [], duplicates: Int = 0, routedElsewhere: Int = 0,
                    changes: [TimelineChange] = [], stateChange: State? = nil) {
            self.applied = applied; self.duplicates = duplicates; self.routedElsewhere = routedElsewhere
            self.changes = changes; self.stateChange = stateChange
        }
    }

    public enum RawRecordError: Error, Sendable, Equatable { case unknownKey, staleLocator }

    // MARK: - Construction

    private let session: SessionID
    private let configHome: URL
    private let mode: Mode
    private let diagnostics: any TimelineDiagnosticsSink
    private let mirrorGapWindow: Duration
    private let tapSettle: Duration

    /// Every effect this actor produces, in order — the tap's and the direct calls' alike. Unbounded on purpose: a
    /// dropped effect would be a dropped `TimelineChange`. One consumer (C6, or a test).
    public nonisolated let effects: AsyncStream<Effect>
    private nonisolated let sink: AsyncStream<Effect>.Continuation

    public init(session: SessionID, configHome: URL, mode: Mode,
                diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics(),
                mirrorGapWindow: Duration = .seconds(2), tapSettle: Duration = .milliseconds(20)) {
        self.session = session
        self.configHome = configHome.standardizedFileURL
        self.mode = mode
        self.diagnostics = diagnostics
        self.mirrorGapWindow = mirrorGapWindow
        self.tapSettle = tapSettle
        (effects, sink) = AsyncStream<Effect>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Internal state

    /// One record as this actor holds it: the decoded record, the key it was applied under, and where its bytes lie
    /// once some file read has shown them. A mirror-delivered record has no locator until the file catches up, which is
    /// why the record itself is retained rather than only its locator.
    struct Entry: Sendable {
        var record: TranscriptRecord
        var key: RecordKey
        var locator: RecordLocator?
    }

    struct FileIdentity: Sendable, Equatable {
        var dev: dev_t
        var ino: ino_t
        var length: Int
    }

    /// The byte range and digest of the raw line of the last file-located record. Every `fileChanged` reads it back
    /// before it reads anything else: an in-place rewrite that keeps the inode and grows the file past the old offset
    /// is invisible to length and identity alone (see `fileChanged`).
    struct TailAnchor: Sendable, Equatable {
        var range: ByteRange
        var sha256: Data
    }

    /// Everything this actor knows about one stream. The names are the spec's: `records` in file order by locator
    /// offset with the mirror-delivered, not-yet-located records after the last located one in delivery order;
    /// `fileUnclaimed`/`mirrorUnclaimed` the two sides of the occurrence rule.
    private struct StreamState: Sendable {
        var path: URL
        var records: [Entry] = []
        var applied: Set<RecordKey> = []
        var locators: [RecordKey: RecordLocator] = [:]
        var offset: Int = 0
        /// The byte offset the tap alignment fixed; the read's start until it runs.
        var cursor: Int = 0
        /// Where the open read began — the counting origin before the alignment runs.
        var readStart: Int = 0
        var fileIdentity: FileIdentity?
        var tailAnchor: TailAnchor?
        var window: WindowMarker?
        /// Per content hash, the ordinals applied so far: the next one to assign.
        var ordinals: [String: Int] = [:]
        /// uuid-less records the file applied at or past the cursor that no mirror delivery has claimed, in file order.
        var fileUnclaimed: [String: [RecordKey]] = [:]
        /// uuid-less records the mirror applied that no file line has confirmed, in delivery order.
        var mirrorUnclaimed: [String: [RecordKey]] = [:]
        /// Under `mirrorPrimary` only: records the watcher applied that no mirror delivery has confirmed.
        var pendingFromFile: [RecordKey: Date] = [:]
        var metadata: AgentMetadataRecord?
    }

    private var streams: [LogicalStream: StreamState] = [:]
    private var mainStream: LogicalStream?
    private var policy: WindowPolicy = .init()
    private var opened = false
    private var closed = false
    private var stateValue: State = .both
    /// The greatest epoch the tap has shown; `.first` before any event.
    private var currentEpoch: ProcessEpoch = .first
    /// A state change the tap observed between effects; it rides the next effect (`processReplaced`).
    private var pendingStateChange: State?
    private var tap: Task<Void, Never>?
    private var gapSweep: Task<Void, Never>?
    /// Non-nil from the start of `open` until the alignment ran. A mirror frame arriving while it is non-nil is
    /// buffered; every other event is handled at once.
    private var buffer: [(frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at: Date)]?
    private var projectionCache: DurableProjection = .empty

    // MARK: - Queries

    public var projection: DurableProjection { projectionCache }
    public var state: State { stateValue }
    public var offsets: [LogicalStream: Int] { streams.mapValues(\.offset) }
    public var paths: [LogicalStream: URL] { streams.mapValues(\.path) }

    // MARK: - Inspection

    /// The keys this ingestion applied for one stream, in the order `records` holds them, each with the locator the
    /// file bound — nil while only the mirror has delivered the record. The projection publishes locators for hidden
    /// records only, so this is the one window onto the arbitration itself.
    func applied(_ stream: LogicalStream) -> [(key: RecordKey, locator: RecordLocator?)] {
        streams[stream]?.records.map { ($0.key, $0.locator) } ?? []
    }
    func locator(of key: RecordKey) -> RecordLocator? {
        streams[key.stream]?.records.first { $0.key == key }?.locator
    }
    func metadata(of stream: LogicalStream) -> AgentMetadataRecord? { streams[stream]?.metadata }
    var openStreams: Set<LogicalStream> { Set(streams.keys) }

    // MARK: - Open

    /// Owns the ordering between the channel's tap — one subscription of C4's per-subscriber fan-out, see `receive` —
    /// and the file: starts a task consuming `events` into a buffer, reads the file (a main path that does not exist
    /// yet is `.mirrorOnly`, not an error), waits until the tap has been quiet for `tapSettle`, aligns the buffer
    /// against the read's tail, applies what the alignment did not claim, and from then on applies each tap event as it
    /// arrives until the sequence ends or `close()`. Returns the projection with the buffer applied. A second `open` on
    /// one actor is a programmer error. An error thrown after the consuming task started cancels it and finishes
    /// `effects` before it propagates.
    @discardableResult
    public func open(file mainPath: URL, events: some AsyncSequence<WireEvent, Never> & Sendable,
                     policy: WindowPolicy = .init()) async throws -> DurableProjection {
        precondition(!opened, "StreamIngestion.open called twice on one actor")
        opened = true
        self.policy = policy
        guard let (main, kind) = TranscriptPath.resolve(mainPath, under: configHome), main.sessionID == session,
              case .mainTranscript(let slug) = kind else {
            preconditionFailure("StreamIngestion.open: the path does not name this session's main transcript")
        }
        mainStream = main

        buffer = []
        tap = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receive(event)
            }
        }

        do {
            streams[main] = StreamState(path: mainPath)
            if let identity = Self.identity(of: mainPath) {
                streams[main]!.fileIdentity = identity
                try readWhole(into: main)
                try openAgentStreams(besides: mainPath, slug: slug, session: main.sessionID)
            } else {
                stateValue = .mirrorOnly
            }

            // The suspension is what lets the consuming task run: the buffer stops growing once the tap is quiet.
            // The wait is capped at `settleRounds` of `tapSettle` in total, because C6 awaits this call before it can
            // render anything and an engine emitting mirror frames faster than `tapSettle` would otherwise stall the
            // channel for as long as the turn runs. Giving up early costs nothing: the alignment is already correct
            // over a partial buffer, and every entry it does not claim is claimed live against `fileUnclaimed` by the
            // ordinary occurrence rule, which is the documented backstop.
            for _ in 0..<Self.settleRounds {
                let before = buffer?.count ?? 0
                try await Task.sleep(for: tapSettle)
                if (buffer?.count ?? 0) == before { break }
            }

            let buffered = buffer ?? []
            alignBuffer(buffered)
            buffer = nil
            projectionCache = recompute()
            for (index, item) in buffered.enumerated() {
                publish(applyMirror(item.frame, epoch: item.epoch, at: item.at, claimed: claimedEntries[index] ?? []))
            }
            claimedEntries = [:]
            return projectionCache
        } catch {
            tap?.cancel()
            tap = nil
            sink.finish()
            closed = true
            throw error
        }
    }

    /// The most `tapSettle` intervals `open` will wait for the tap to fall quiet before it aligns regardless.
    static let settleRounds = 50

    /// Set by `alignBuffer`: buffered frame index → the entry indices the alignment claimed against the read.
    private var claimedEntries: [Int: Set<Int>] = [:]

    /// The whole file (or its initial window) into a stream that holds nothing yet.
    private func readWhole(into stream: LogicalStream) throws {
        guard var st = streams[stream] else { return }
        let result = try WindowedTranscript.read(TranscriptReader(url: st.path), policy: policy)
        var applied: [RecordKey] = []
        var duplicates = 0
        st.readStart = result.ranges.first?.offset ?? 0
        st.cursor = st.readStart
        apply(fileRecords: result.records, ranges: result.ranges, stream: stream, into: &st,
              seedUnclaimed: false, trackPending: false, now: Date(), applied: &applied, duplicates: &duplicates)
        st.offset = result.length
        st.window = result.window
        refreshAnchor(&st, ranges: result.ranges)
        streams[stream] = st
    }

    /// `<slug>/<sessionId>/subagents/agent-*.jsonl` beside the main file, each opened whole, plus every `.meta.json`.
    private func openAgentStreams(besides mainPath: URL, slug: String, session id: SessionID) throws {
        let directory = mainPath.deletingLastPathComponent().appendingPathComponent("\(id)", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            guard let (stream, kind) = TranscriptPath.resolve(url, under: configHome), stream.sessionID == session else { continue }
            switch kind {
            case .agentTranscript:
                guard let identity = Self.identity(of: url) else { continue }
                var st = StreamState(path: url)
                st.fileIdentity = identity
                streams[stream] = st
                try readWhole(into: stream)
            case .agentMetadata:
                loadMetadata(at: url, into: stream)
            case .mainTranscript:
                continue
            }
        }
    }

    /// The `.meta.json` sidecar. It carries no `type` key — the mirror's own entry is the same body with
    /// `"type": "agent_metadata"` added — so the key is supplied here and the two decode to one record. The stream's
    /// transcript path is the sidecar's with the suffix swapped, so a sidecar that arrives first still names where the
    /// transcript will be.
    private func loadMetadata(at url: URL, into stream: LogicalStream) {
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else { return }
        if object["type"] == nil { object["type"] = .string("agent_metadata") }
        guard case .agentMetadata(let record, _) = RecordDecoder.decode(entry: .object(object)) else { return }
        let transcript = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
        streams[stream, default: StreamState(path: transcript)].metadata = record
    }

    // MARK: - The alignment

    /// One record the open read, in file order.
    struct TailRecord: Sendable { var uuid: String?; var hash: String; var range: Range<Int> }
    /// One buffered mirror entry, in arrival order.
    struct BufferedEntry: Sendable { var frame: Int; var entry: Int; var uuid: String?; var hash: String }
    /// Buffered position → tail index, plus the cursor in bytes.
    struct Alignment: Sendable, Equatable { var claims: [Int: Int]; var cursor: Int }

    /// Pure. Two identities are equal when both carry the same uuid, or neither carries one and the hashes are equal.
    ///
    /// The anchors are the buffered uuid entries whose uuid the tail holds, taken in buffer order with strictly
    /// increasing tail indices (one that goes backwards is not a write-order record and is skipped). With at least one
    /// anchor, each anchor claims its record and the uuid-less buffered entries between consecutive fixed points — the
    /// read's start, each anchor, the read's end — claim the tail's unclaimed uuid-less records between the same fixed
    /// points by hash, in order. With no anchor, k is the largest count such that the first k buffered identities equal
    /// the tail's last k identities, and those k pairs are claimed.
    ///
    /// A claim never creates a record, a wrong claim costs only the latency until the watcher shows the line, and a
    /// missed claim is a phantom no fold removes, so ties go to claiming.
    static func align(buffered: [BufferedEntry], tail: [TailRecord], readStart: Int) -> Alignment {
        var claims: [Int: Int] = [:]
        guard !buffered.isEmpty, !tail.isEmpty else { return Alignment(claims: [:], cursor: readStart) }

        var tailIndexByUUID: [String: Int] = [:]
        for (index, record) in tail.enumerated() {
            guard let uuid = record.uuid, tailIndexByUUID[uuid] == nil else { continue }
            tailIndexByUUID[uuid] = index
        }

        var anchors: [(buffered: Int, tail: Int)] = []
        var highest = -1
        for (index, entry) in buffered.enumerated() {
            guard let uuid = entry.uuid, let position = tailIndexByUUID[uuid], position > highest else { continue }
            anchors.append((index, position))
            highest = position
        }

        if anchors.isEmpty {
            let limit = min(buffered.count, tail.count)
            var best = 0
            for k in stride(from: limit, through: 1, by: -1) {
                let offset = tail.count - k
                var matches = true
                for i in 0..<k where !same(buffered[i], tail[offset + i]) { matches = false; break }
                if matches { best = k; break }
            }
            for i in 0..<best { claims[i] = tail.count - best + i }
        } else {
            var claimedTail: Set<Int> = []
            for anchor in anchors { claims[anchor.buffered] = anchor.tail; claimedTail.insert(anchor.tail) }
            // The spans between consecutive fixed points: the read's start, each anchor, the read's end.
            var spans: [(buffered: Range<Int>, tail: Range<Int>)] = []
            var previous = (buffered: 0, tail: 0)
            for anchor in anchors {
                spans.append((previous.buffered..<anchor.buffered, previous.tail..<anchor.tail))
                previous = (anchor.buffered + 1, anchor.tail + 1)
            }
            spans.append((previous.buffered..<buffered.count, previous.tail..<tail.count))
            for span in spans {
                var next = span.tail.lowerBound
                for position in span.buffered {
                    guard buffered[position].uuid == nil else { continue }      // a uuid the tail does not hold
                    var candidate = next
                    while candidate < span.tail.upperBound {
                        let record = tail[candidate]
                        if record.uuid == nil, !claimedTail.contains(candidate), record.hash == buffered[position].hash { break }
                        candidate += 1
                    }
                    guard candidate < span.tail.upperBound else { continue }
                    claims[position] = candidate
                    claimedTail.insert(candidate)
                    next = candidate + 1
                }
            }
        }

        let cursor = claims.values.map { tail[$0].range.upperBound }.max() ?? readStart
        return Alignment(claims: claims, cursor: cursor)
    }

    private static func same(_ entry: BufferedEntry, _ record: TailRecord) -> Bool {
        if let a = entry.uuid, let b = record.uuid { return a == b }
        if entry.uuid == nil, record.uuid == nil { return entry.hash == record.hash }
        return false
    }

    /// Runs the alignment for every stream the open read, fixes each cursor, seeds `fileUnclaimed` with the read's
    /// unclaimed uuid-less records at or past that cursor, and records one `tapAligned` notice per stream that had
    /// buffered entries. A stream with no buffered entry still runs: its cursor is the read's start and every uuid-less
    /// record it read is unclaimed, which is what lets a mirror frame arriving after `open` claim the line the read
    /// already applied instead of applying it twice.
    private func alignBuffer(_ buffered: [(frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at: Date)]) {
        var perStream: [LogicalStream: [BufferedEntry]] = [:]
        for (frameIndex, item) in buffered.enumerated() {
            guard let (stream, _) = resolve(item.frame.filePath), streams[stream] != nil else { continue }
            for (entryIndex, value) in item.frame.entries.enumerated() {
                let record = RecordDecoder.decode(entry: value)
                if case .agentMetadata = record { continue }
                perStream[stream, default: []].append(
                    BufferedEntry(frame: frameIndex, entry: entryIndex, uuid: record.uuid,
                                  hash: record.contentHash ?? ""))
            }
        }

        for stream in streams.keys.sorted(by: { $0.name.label < $1.name.label }) {
            guard var st = streams[stream] else { continue }
            let entries = perStream[stream] ?? []
            var tail: [TailRecord] = []
            var tailKeys: [RecordKey] = []
            for entry in st.records {
                guard let locator = entry.locator else { continue }
                tail.append(TailRecord(uuid: entry.record.uuid, hash: entry.record.contentHash ?? "",
                                       range: locator.range.offset..<(locator.range.offset + locator.range.length)))
                tailKeys.append(entry.key)
            }
            let alignment = Self.align(buffered: entries, tail: tail, readStart: st.readStart)
            st.cursor = alignment.cursor
            for position in alignment.claims.keys {
                claimedEntries[entries[position].frame, default: []].insert(entries[position].entry)
            }
            let claimedTail = Set(alignment.claims.values)
            for (index, record) in tail.enumerated() where record.uuid == nil && !claimedTail.contains(index)
                && record.range.lowerBound >= st.cursor {
                st.fileUnclaimed[record.hash, default: []].append(tailKeys[index])
            }
            streams[stream] = st
            guard !entries.isEmpty else { continue }
            diagnostics.record(.tapAligned(session: session, stream: stream.name,
                                           claimed: alignment.claims.count,
                                           unclaimed: entries.count - alignment.claims.count))
        }
    }

    // MARK: - The tap

    /// The consuming task's call. `transcript_mirror`, `system/mirror_error` and `exited` are this actor's; every other
    /// event belongs to the channel's `WireReducer`, which holds its own subscription of C4's per-subscriber fan-out,
    /// so ignoring it here loses nothing.
    func receive(_ event: WireEvent) async {
        if let epoch = Self.epoch(of: event) {
            if epoch > currentEpoch { currentEpoch = epoch }
            if case .fileOnly(let since) = stateValue, epoch > since {
                stateValue = .both
                pendingStateChange = .both
            }
        }
        switch event {
        case .frame(.transcriptMirror(let frame), let epoch):
            if buffer != nil { buffer?.append((frame, epoch, Date())) }
            else { publish(apply(mirror: frame, epoch: epoch, at: Date())) }
        case .frame(.system(.mirrorError(let error)), let epoch):
            publish(mirrorError(error, epoch: epoch))
        case .exited(_, let epoch):
            publish(await processExited(epoch))
        default:
            break
        }
    }

    private static func epoch(of event: WireEvent) -> ProcessEpoch? {
        switch event {
        case .handshakeCompleted(_, let e), .sessionIdentityResolved(_, let e), .frame(_, let e),
             .requestCancelled(_, let e), .hostToolInvoked(_, let e), .stderr(_, let e), .exited(_, let e):
            return e
        case .request(let r), .unansweredDialog(let r), .policyAnswered(let r, _):
            return r.epoch
        }
    }

    // MARK: - The mirror

    func apply(mirror frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at now: Date) -> Effect {
        applyMirror(frame, epoch: epoch, at: now, claimed: [])
    }

    /// `claimed` names the entry indices the open alignment already matched against a line the read applied: they are
    /// counted as duplicates and never applied.
    private func applyMirror(_ frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at now: Date,
                             claimed: Set<Int>) -> Effect {
        var effect = Effect()
        guard let (stream, _) = resolve(frame.filePath) else {
            effect.routedElsewhere = 1
            diagnostics.record(.mirrorRoutedElsewhere(session: session, epoch: epoch))
            return effect
        }
        if case .fileOnly = stateValue { return effect }

        var st = streams[stream] ?? StreamState(path: URL(fileURLWithPath: frame.filePath))
        for (index, value) in frame.entries.enumerated() {
            let record = RecordDecoder.decode(entry: value)
            if case .agentMetadata(let metadata, _) = record { st.metadata = metadata; continue }
            if claimed.contains(index) { effect.duplicates += 1; continue }
            if let uuid = record.uuid {
                let key = RecordKey(stream: stream, identity: .uuid(uuid))
                if st.applied.contains(key) {
                    effect.duplicates += 1
                    st.pendingFromFile[key] = nil
                    continue
                }
                st.applied.insert(key)
                st.records.append(Entry(record: record, key: key, locator: nil))
                effect.applied.append(key)
                continue
            }
            let hash = record.contentHash ?? ""
            if var unclaimed = st.fileUnclaimed[hash], !unclaimed.isEmpty {
                let key = unclaimed.removeFirst()
                st.fileUnclaimed[hash] = unclaimed.isEmpty ? nil : unclaimed
                effect.duplicates += 1
                st.pendingFromFile[key] = nil
                continue
            }
            let ordinal = st.ordinals[hash, default: 0]
            st.ordinals[hash] = ordinal + 1
            let key = RecordKey(stream: stream, identity: .hash(hash, ordinal: ordinal))
            st.applied.insert(key)
            st.records.append(Entry(record: record, key: key, locator: nil))
            st.mirrorUnclaimed[hash, default: []].append(key)
            effect.applied.append(key)
        }
        st.records = Self.ordered(st.records)
        streams[stream] = st
        return effect
    }

    /// From the tap's `system` frame. Idempotent within the epoch.
    func mirrorError(_ error: MirrorError, epoch: ProcessEpoch) -> Effect {
        var effect = Effect()
        if case .fileOnly(let since) = stateValue, since == epoch { return effect }
        stateValue = .fileOnly(since: epoch)
        effect.stateChange = stateValue
        diagnostics.record(.mirrorErrorSwitchedToFileOnly(session: session, stream: Self.streamName(of: error),
                                                          epoch: epoch))
        return effect
    }

    /// `key` is `{projectKey, sessionId, subpath?}`; only a `subagents/agent-<id>.jsonl` subpath names an agent stream.
    private static func streamName(of error: MirrorError) -> StreamName {
        guard let subpath = error.fields.key["subpath"]?.stringValue,
              subpath.hasPrefix("subagents/agent-"), subpath.hasSuffix(".jsonl") else { return .main }
        return .agent(taskID: String(subpath.dropFirst("subagents/agent-".count).dropLast(6)))
    }

    // MARK: - The file

    /// The watcher's change for one path. `fstat` and the tail anchor are read before anything else: a length shorter
    /// than the stream's offset, a changed `(st_dev, st_ino)`, a short read of the anchor's range or a digest other
    /// than the anchor's each means the bytes behind the offset are not the bytes that were applied, and the stream is
    /// rebuilt whole rather than read from a stale offset (spec "The rewrite arm").
    @discardableResult
    public func fileChanged(_ path: URL, at now: Date = Date()) async -> Effect {
        var effect = Effect()
        guard let (stream, kind) = resolve(path.path) else { return publish(effect) }
        if case .agentMetadata = kind {
            loadMetadata(at: path, into: stream)
            return publish(effect)
        }
        var st = streams[stream] ?? StreamState(path: path)
        guard let identity = Self.identity(of: st.path) else {
            streams[stream] = st
            return publish(effect)                                  // the file still does not exist
        }

        if st.fileIdentity == nil {
            st.fileIdentity = identity
            readAppend(from: 0, stream: stream, into: &st, now: now, effect: &effect)
            streams[stream] = st
            if stream == mainStream, stateValue == .mirrorOnly {
                stateValue = .both
                effect.stateChange = .both
            }
            armGapSweep()
            return publish(effect)
        }

        let rewritten = identity.length < st.offset
            || identity.dev != st.fileIdentity!.dev
            || identity.ino != st.fileIdentity!.ino
            || !anchorHolds(st)
        if rewritten {
            rebuild(stream: stream, into: &st, identity: identity, effect: &effect)
            streams[stream] = st
            return publish(effect)
        }

        st.fileIdentity = identity
        readAppend(from: st.offset, stream: stream, into: &st, now: now, effect: &effect)
        streams[stream] = st
        armGapSweep()
        return publish(effect)
    }

    private func readAppend(from offset: Int, stream: LogicalStream, into st: inout StreamState, now: Date,
                            effect: inout Effect, trackPending: Bool? = nil) {
        guard let result = try? TranscriptReader(url: st.path).readAppended(from: offset) else { return }
        apply(fileRecords: result.records, ranges: result.ranges, stream: stream, into: &st,
              seedUnclaimed: true, trackPending: trackPending ?? (mode == .mirrorPrimary), now: now,
              applied: &effect.applied, duplicates: &effect.duplicates)
        st.offset = result.length
        refreshAnchor(&st, ranges: result.ranges)
    }

    /// The whole stream replaced: records, applied set, locators, ordinals, both unclaimed maps, cursor and window.
    /// One payload-free `fileRewritten`, and `State` untouched. The only event that renumbers a published key.
    private func rebuild(stream: LogicalStream, into st: inout StreamState, identity: FileIdentity,
                         effect: inout Effect) {
        guard let result = try? WindowedTranscript.read(TranscriptReader(url: st.path), policy: policy) else { return }
        let previousLength = st.offset
        st.records = []; st.applied = []; st.locators = [:]; st.ordinals = [:]
        st.fileUnclaimed = [:]; st.mirrorUnclaimed = [:]; st.pendingFromFile = [:]
        st.readStart = result.ranges.first?.offset ?? 0
        var duplicates = 0
        apply(fileRecords: result.records, ranges: result.ranges, stream: stream, into: &st,
              seedUnclaimed: false, trackPending: false, now: Date(), applied: &effect.applied,
              duplicates: &duplicates)
        st.offset = result.length
        st.cursor = result.length
        st.fileUnclaimed = [:]
        st.window = result.window
        st.fileIdentity = identity
        refreshAnchor(&st, ranges: result.ranges)
        diagnostics.record(.fileRewritten(session: session, stream: stream.name,
                                          previousLength: previousLength, newLength: result.length))
    }

    /// The append rule, shared by `open`'s read, `fileChanged` and `processExited`. A uuid record binds its locator
    /// first — that is what closes a mirror-delivered record's nil locator — and is a duplicate when it is applied
    /// already; a uuid-less record claims the earliest unconfirmed mirror delivery of its hash, or is new.
    private func apply(fileRecords records: [TranscriptRecord], ranges: [ByteRange], stream: LogicalStream,
                       into st: inout StreamState, seedUnclaimed: Bool, trackPending: Bool, now: Date,
                       applied: inout [RecordKey], duplicates: inout Int) {
        for (record, range) in zip(records, ranges) {
            let locator = RecordLocator(stream: stream, range: range)
            if let uuid = record.uuid {
                let key = RecordKey(stream: stream, identity: .uuid(uuid))
                if st.applied.contains(key) {
                    bind(key, to: locator, in: &st)
                    duplicates += 1
                    continue
                }
                st.applied.insert(key)
                st.locators[key] = locator
                st.records.append(Entry(record: record, key: key, locator: locator))
                applied.append(key)
                if trackPending { st.pendingFromFile[key] = now }
                continue
            }
            let hash = record.contentHash ?? ""
            if var unclaimed = st.mirrorUnclaimed[hash], !unclaimed.isEmpty {
                let key = unclaimed.removeFirst()
                st.mirrorUnclaimed[hash] = unclaimed.isEmpty ? nil : unclaimed
                bind(key, to: locator, in: &st)
                duplicates += 1
                continue
            }
            let ordinal = st.ordinals[hash, default: 0]
            st.ordinals[hash] = ordinal + 1
            let key = RecordKey(stream: stream, identity: .hash(hash, ordinal: ordinal))
            st.applied.insert(key)
            st.locators[key] = locator
            st.records.append(Entry(record: record, key: key, locator: locator))
            applied.append(key)
            if seedUnclaimed { st.fileUnclaimed[hash, default: []].append(key) }
            if trackPending { st.pendingFromFile[key] = now }
        }
        st.records = Self.ordered(st.records)
    }

    private func bind(_ key: RecordKey, to locator: RecordLocator, in st: inout StreamState) {
        st.locators[key] = locator
        for index in st.records.indices where st.records[index].key == key {
            st.records[index].locator = locator
        }
        st.pendingFromFile[key] = nil
    }

    /// File order by locator offset, with the records the mirror delivered and the file has not yet shown after the
    /// last located one, in delivery order.
    private static func ordered(_ entries: [Entry]) -> [Entry] {
        var located: [(index: Int, entry: Entry)] = []
        var free: [Entry] = []
        for (index, entry) in entries.enumerated() {
            if entry.locator != nil { located.append((index, entry)) } else { free.append(entry) }
        }
        located.sort { a, b in
            let x = a.entry.locator!.range.offset, y = b.entry.locator!.range.offset
            return x == y ? a.index < b.index : x < y
        }
        return located.map(\.entry) + free
    }

    private func refreshAnchor(_ st: inout StreamState, ranges: [ByteRange]) {
        guard let last = ranges.last,
              let bytes = try? TranscriptReader(url: st.path).read(at: last.offset, length: last.length),
              bytes.count == last.length else { return }
        st.tailAnchor = TailAnchor(range: last, sha256: Data(SHA256.hash(data: bytes)))
    }

    private func anchorHolds(_ st: StreamState) -> Bool {
        guard let anchor = st.tailAnchor else { return true }       // no located record yet: nothing to check
        guard let bytes = try? TranscriptReader(url: st.path).read(at: anchor.range.offset, length: anchor.range.length),
              bytes.count == anchor.range.length else { return false }
        return Data(SHA256.hash(data: bytes)) == anchor.sha256
    }

    // MARK: - The mirror gap

    /// The deadline's body. Entries older than `mirrorGapWindow` are removed and counted; a non-zero count switches the
    /// state once, emits one effect with no keys and the `stateChange`, and records one `mirrorGap` per stream swept.
    /// No file event is required: the coalesced watcher event that would have caught it may never come.
    func sweepGaps(at now: Date) {
        gapSweep = nil
        var swept = 0
        var switched: State?
        for (stream, var st) in streams {
            let expired = st.pendingFromFile.filter { now.timeIntervalSince($0.value) >= Self.seconds(mirrorGapWindow) }
            guard !expired.isEmpty else { continue }
            for key in expired.keys { st.pendingFromFile[key] = nil }
            streams[stream] = st
            swept += expired.count
            diagnostics.record(.mirrorGap(session: session, stream: stream.name, missing: expired.count,
                                          epoch: currentEpoch))
            if case .fileOnly = stateValue {} else {
                stateValue = .fileOnly(since: currentEpoch)
                switched = stateValue
            }
        }
        if swept > 0 {
            var effect = Effect()
            effect.stateChange = switched
            publish(effect)
        }
        armGapSweep()
    }

    private func armGapSweep() {
        guard mode == .mirrorPrimary, gapSweep == nil, !closed else { return }
        let oldest = streams.values.flatMap { $0.pendingFromFile.values }.min()
        guard let oldest else { return }
        let remaining = max(0, Self.seconds(mirrorGapWindow) - Date().timeIntervalSince(oldest))
        gapSweep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            await self?.sweepGaps(at: Date())
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - Process exit

    /// For every stream that has a file, read from its offset and apply what is missing by the `fileChanged` rule, then
    /// clear both unclaimed maps and set the cursor to the stream's offset: the next epoch's mirror carries only later
    /// appends and is matched afresh from there. `ordinals` stay. A `fileOnly` state persists until the tap's first
    /// event under a greater epoch.
    func processExited(_ epoch: ProcessEpoch) async -> Effect {
        var effect = Effect()
        for (stream, var st) in streams {
            guard st.fileIdentity != nil, Self.identity(of: st.path) != nil else { continue }
            // `trackPending: false`, unconditionally. Under `mirrorPrimary` an ordinary watcher read remembers each
            // record until the mirror confirms it, but the process this reconciliation closes out has already exited
            // and will mirror nothing ever again: every record applied here would sit pending until the next
            // `fileChanged` armed the sweep, and then expire together and switch the state to `fileOnly` for a gap
            // that is not one. The mirror being definitionally gone is why nothing is remembered rather than why
            // everything is forgotten afterwards.
            readAppend(from: st.offset, stream: stream, into: &st, now: Date(), effect: &effect,
                       trackPending: false)
            st.fileUnclaimed = [:]
            st.mirrorUnclaimed = [:]
            st.cursor = st.offset
            streams[stream] = st
        }
        return effect
    }

    // MARK: - Load earlier

    /// The C6 contract behind the affordance, since C6 reads no JSONL: continue from the main stream's window marker,
    /// prepend the records with fresh occurrence ordinals and locators, move the marker. An empty effect when
    /// `earlierAvailable == false`.
    @discardableResult
    public func loadEarlier() async throws -> Effect {
        var effect = Effect()
        guard let main = mainStream, var st = streams[main], let marker = st.window, marker.earlierAvailable else {
            return publish(effect)
        }
        let result = try WindowedTranscript.readEarlier(TranscriptReader(url: st.path), held: st.records.map(\.record),
                                                        window: marker, policy: policy)
        for (record, range) in zip(result.records, result.ranges) {
            let locator = RecordLocator(stream: main, range: range)
            let key: RecordKey
            if let uuid = record.uuid {
                key = RecordKey(stream: main, identity: .uuid(uuid))
            } else {
                let hash = record.contentHash ?? ""
                let ordinal = st.ordinals[hash, default: 0]
                st.ordinals[hash] = ordinal + 1
                key = RecordKey(stream: main, identity: .hash(hash, ordinal: ordinal))
            }
            guard !st.applied.contains(key) else { continue }
            st.applied.insert(key)
            st.locators[key] = locator
            st.records.append(Entry(record: record, key: key, locator: locator))
            effect.applied.append(key)
        }
        st.records = Self.ordered(st.records)
        st.window = result.window
        if let first = result.ranges.first { st.readStart = min(st.readStart, first.offset) }
        streams[main] = st
        return publish(effect)
    }

    // MARK: - Relocation and close

    /// Rebind the main stream's path and every agent stream's path under the new slug. Offsets, locators and file
    /// identity are unchanged: a locator is a stream plus a range and the stream did not change, and a rename keeps the
    /// inode, so the next `fileChanged` does not take the rewrite arm.
    public func relocated(mainPath: URL) async {
        guard let main = mainStream,
              let (stream, kind) = TranscriptPath.resolve(mainPath, under: configHome), stream == main,
              case .mainTranscript(let slug) = kind else { return }
        for (id, var st) in streams {
            switch id.name {
            case .main:
                st.path = mainPath
            case .agent:
                st.path = TranscriptPath.path(of: id, slug: slug)
            }
            streams[id] = st
        }
        diagnostics.record(.relocationFollowed(session: session))
    }

    /// Cancels the consuming task and the gap sweep and finishes `effects`; every query still answers.
    public func close() {
        closed = true
        tap?.cancel(); tap = nil
        gapSweep?.cancel(); gapSweep = nil
        sink.finish()
    }

    // MARK: - The raw view

    /// The record's bytes through `TranscriptReader.read(at:length:)` at its locator, decoded and verified: the decoded
    /// record's uuid, or its `contentHash`, must be the key's, else `staleLocator` — a locator from before a rewrite
    /// this actor has not yet seen, never another record's bytes. A record the mirror delivered before the file held it
    /// is served from the retained record until `fileChanged` sees it on disk. Nothing is cached.
    public func rawRecord(for key: RecordKey) async throws -> JSONValue {
        guard let st = streams[key.stream], let entry = st.records.first(where: { $0.key == key }) else {
            throw RawRecordError.unknownKey
        }
        guard let locator = entry.locator else { return try entry.record.rawJSON() }
        guard let bytes = try? TranscriptReader(url: streams[locator.stream]?.path ?? st.path)
                .read(at: locator.range.offset, length: locator.range.length),
              bytes.count == locator.range.length,
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
            throw RawRecordError.staleLocator
        }
        let decoded = RecordDecoder.decode(line: bytes)
        switch key.identity {
        case .uuid(let uuid):
            guard decoded.uuid == uuid else { throw RawRecordError.staleLocator }
        case .hash(let hash, _):
            guard decoded.contentHash == hash else { throw RawRecordError.staleLocator }
        }
        return value
    }

    // MARK: - Projection

    private func recompute() -> DurableProjection {
        guard let main = mainStream else { return .empty }
        var projections: [StreamProjection] = []
        for stream in streams.keys.sorted(by: { $0.name.label < $1.name.label }) {
            guard let st = streams[stream] else { continue }
            let records = st.records.map(\.record)
            var options = RecordReducer.Options()
            options.window = st.window
            // The reducer numbers occurrences in the order of the array it is handed; this actor numbers them in
            // application order, and the two part after a `loadEarlier` prepend. The locators are therefore mapped
            // positionally onto the reducer's own keys rather than by this actor's.
            let keys = RecordKey.keys(for: records, in: stream)
            var locators: [RecordKey: RecordLocator] = [:]
            for (index, key) in keys.enumerated() {
                if let locator = st.records[index].locator { locators[key] = locator }
            }
            options.locators = locators
            var projection = RecordReducer.reduce(records, stream: stream, sourceFile: st.path,
                                                  origin: .file, options: options)
            if let metadata = st.metadata { projection.metadata = metadata }
            projections.append(projection)
        }
        return RecordReducer.merge(projections, main: main)
    }

    @discardableResult
    private func publish(_ effect: Effect) -> Effect {
        var effect = effect
        if effect.stateChange == nil, let pending = pendingStateChange {
            effect.stateChange = pending
        }
        pendingStateChange = nil
        let previous = projectionCache
        projectionCache = recompute()
        effect.changes = Self.changes(from: previous, to: projectionCache)
        sink.yield(effect)
        return effect
    }

    private static func changes(from old: DurableProjection, to new: DurableProjection) -> [TimelineChange] {
        var before: [ItemID: TimelineItem] = [:]
        for item in old.items { before[item.id] = item }
        var after: [ItemID: TimelineItem] = [:]
        for item in new.items { after[item.id] = item }
        var out: [TimelineChange] = []
        for item in new.items {
            guard let previous = before[item.id] else { out.append(.inserted(item.id)); continue }
            if previous != item { out.append(.updated(item.id)) }
        }
        for item in old.items where after[item.id] == nil { out.append(.removed(item.id)) }
        if old.session != new.session { out.append(.sessionStateChanged) }
        return out
    }

    // MARK: - Paths and files

    private func resolve(_ path: String) -> (LogicalStream, TranscriptPath)? {
        guard let resolved = TranscriptPath.resolve(URL(fileURLWithPath: path), under: configHome),
              resolved.0.sessionID == session else { return nil }
        return resolved
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }) == 0 else { return nil }
        return FileIdentity(dev: info.st_dev, ino: info.st_ino, length: Int(info.st_size))
    }
}

extension TranscriptRecord {
    /// The record as the raw view shows it, for a record the mirror delivered and no file line has yet located.
    func rawJSON() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode(self))
    }
}
