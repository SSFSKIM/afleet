import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

extension ComposerModel {

    /// The two reports this channel's engine has already made, taken once as the subscription starts.
    ///
    /// **`events(of:)` is a future-only fan-out.** Neither the handshake nor `system/init` is ever
    /// sent twice, so a composer mounted onto a channel that came up minutes ago sees neither: no
    /// `current_permission_mode` for the mode picker to display, and no engine command list for
    /// autocomplete to offer. What the user *types* still routes correctly — `route(_:on:)` reads the
    /// supervisor's own retained copies — which is exactly why the gap was invisible from the
    /// dispatch side; what was missing was the surface's own copy of the same two values, and X5's
    /// `engineReports(of:)` is it.
    ///
    /// Seeded and never merged: anything the stream delivers afterwards is newer by construction and
    /// overwrites this. A channel the fleet owns no supervisor for answers nil, and a composer over
    /// an archived channel shows nothing — which is what it should show.
    ///
    /// **Fenced on the subscription that asked for it.** Everything here is committed after an await — the query
    /// itself, and `noteHandshake`, which can issue two control requests of its own before the picker's values land.
    /// A `stop()` with a fresh `start()` behind it can land in either window, and this call then goes on writing for
    /// a subscription nobody reads. Its answers are older than the new one's by construction, so the handshake, the
    /// mode readback and `system/init` would each land stale over values the current subscription has already
    /// applied. The generation is re-read after every await rather than once at entry, because every await is a
    /// fresh chance to lose it.
    func seedEngineReports(ifGenerationIs subscription: Int) async {
        guard let reports = await lifecycle.engineReports(of: key) else { return }
        guard isCurrentSubscription(subscription) else { return }
        if let handshake = reports.handshake {
            self.handshake = handshake
            // The mode picker's readback — as a **retained** report, not as a live handshake. Every
            // remount re-runs this seeding, so the picker is handed a report it may well have seen
            // already, and one older than any mode the user has asked for since. Read as the answer
            // to that request it would call a change that succeeded a disagreement, and leave the
            // restart snapshot naming a mode the process no longer runs.
            await pickers.noteRetainedHandshake(handshake)
            guard isCurrentSubscription(subscription) else { return }
        }
        if let systemInit = reports.systemInit { self.systemInit = systemInit }
    }
}
