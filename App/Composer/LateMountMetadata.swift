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
    func seedEngineReports() async {
        guard let reports = await lifecycle.engineReports(of: key) else { return }
        if let handshake = reports.handshake {
            self.handshake = handshake
            // The mode picker's readback, on the same terms a live handshake sets it.
            await pickers.noteHandshake(handshake)
        }
        if let systemInit = reports.systemInit { self.systemInit = systemInit }
    }
}
