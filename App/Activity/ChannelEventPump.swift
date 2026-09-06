import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// One channel's `events(of:)` subscription, fanned out inside the app (spec §5).
///
/// **One subscription per owned channel, and this is it.** `LifecycleAPI.events(of:)` hands back a
/// fresh unbounded fan-out on every call, so a second caller costs a second copy of every frame;
/// the app therefore takes exactly one per channel here and gives every consumer inside the app
/// what it already folded. Task 7's `StreamIngestion` takes its own, which is C3's tap contract
/// and not a duplicate of this one — it consumes the raw stream, where this keeps three summaries.
///
/// What it keeps is exactly what `ActivityQuery.rows(states:mirrors:recent:)` asks for, plus the
/// one thing `ChannelState` does not carry:
/// - `recent`, a **bounded** ring of frames. A channel that runs all day must not grow a transcript
///   in memory, and Activity reads only the tail: the rate-limit notice, the authentication report,
///   the failed results.
/// - `mirror`, C3's `RegistryMirror`, whose `RegistryEntry` already conforms to
///   `TaskMirrorReading`, so the running-agent rows are C3's own fold rather than a second one.
/// - `requests`, the surfaced `InboundRequest`s by id. `PendingDecision` carries no payload — an id,
///   a subtype, an epoch and a timestamp — so the *contents* of a decision card, and with them the
///   answer to "may this be answered inline?", exist only on the `.request` event.
@MainActor
final class ChannelEventPump {

    /// How many frames the ring holds. Sized for the tail Activity reads, not for a transcript.
    static let recentCapacity = 256

    /// How many pumps may exist at once: C4's fleet-wide cap on owned processes, which is the
    /// number of channels that can be delivering events at all. Read from C4 rather than restated,
    /// so raising the cap there does not leave a second six behind here.
    static let maximumPumps = FleetCapCounter.capacity

    let key: ChannelKey

    /// The tail of this channel's frames, oldest dropped once the ring is full.
    private(set) var recent: [Frame] = []
    /// C3's background-task registry for this channel.
    private(set) var mirror = RegistryMirror()
    /// Every surfaced request this channel has open, by id.
    private(set) var requests: [RequestID: InboundRequest] = [:]
    /// The last epoch an event carried, for a frame that needs one.
    private(set) var epoch: ProcessEpoch = .first

    /// Called after every event, once the three summaries above are already updated, so a consumer
    /// that re-reads the pump sees the event it is being told about.
    private let onEvent: @MainActor (ChannelEventPump, WireEvent) -> Void
    private var task: Task<Void, Never>?

    init(key: ChannelKey, onEvent: @escaping @MainActor (ChannelEventPump, WireEvent) -> Void) {
        self.key = key
        self.onEvent = onEvent
    }

    /// Consumes `stream` until it finishes or `stop()` is called. Idempotent: a second call while
    /// one is running is ignored, because a channel with two loops over two fan-outs would count
    /// every frame twice.
    func start(_ stream: AsyncStream<WireEvent>) {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.ingest(event)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Folds one event. Synchronous and public to the app so a test drives the pump with the frames
    /// a fixture recorded rather than with a process.
    func ingest(_ event: WireEvent) {
        switch event {
        case .frame(let frame, let epoch):
            self.epoch = epoch
            if case .system(let system) = frame {
                mirror.apply(system, at: Date(), epoch: epoch)
            }
            append(frame)

        case .request(let request):
            epoch = request.epoch
            requests[request.id] = request

        case .requestCancelled(let id, let epoch):
            self.epoch = epoch
            requests[id] = nil

        case .handshakeCompleted(_, let epoch), .hostToolInvoked(_, let epoch):
            self.epoch = epoch

        case .exited(_, let epoch):
            self.epoch = epoch
            // Every request of a dead process is dead with it, and its background tasks are its
            // children and died too. Keeping either would leave Activity offering to answer a
            // prompt nothing is listening for. The frame ring is left alone: it is what the last
            // rate-limit notice and the last authentication report live in, and those outlive the
            // process that reported them (§7.6).
            requests.removeAll()
            mirror = RegistryMirror()

        case .policyAnswered, .unansweredDialog, .sessionIdentityResolved, .stderr:
            break
        }
        onEvent(self, event)
    }

    /// Drops a request the app has answered. The engine sends no frame back for an answer, so
    /// nothing else would remove it, and a card left in `requests` would keep offering to answer a
    /// question that is closed.
    func forget(_ id: RequestID) { requests[id] = nil }

    /// The mirror rows `ActivityQuery` reads: C3's own live set, not every row ever seen.
    var liveWork: [any TaskMirrorReading] { mirror.liveWork(asOf: Date()) }

    private func append(_ frame: Frame) {
        recent.append(frame)
        if recent.count > Self.recentCapacity {
            recent.removeFirst(recent.count - Self.recentCapacity)
        }
    }
}
