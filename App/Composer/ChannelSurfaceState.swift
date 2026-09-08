import Foundation
import Observation

/// The one seam between the composer and the channel header (spec §8.5, C6.2 "The shape: two
/// models, one seam").
///
/// The two models have different lifetimes: the composer's draft survives a header action, and a
/// header action that restarts the channel has to be able to disable the field without owning what
/// is typed in it. So the header writes here and the composer reads here, and nothing else crosses
/// between them.
///
/// Deliberately three fields and no logic. Anything derived — which action set the reason, how long
/// a restart has been in flight — belongs to the model that knows it, because a seam that computes
/// is a second opinion about state its two users already hold.
@MainActor
@Observable
final class ChannelSurfaceState {

    /// The composer refuses to send while this is true: §7.4's rule that the field is closed while a
    /// restart is in flight and while a readback is still unconfirmed.
    var isDisabled: Bool

    /// What the composer shows in place of the field. Nil while `isDisabled` is false; a sentence
    /// naming the setting or the operation while it is true.
    var disabledReason: String?

    /// A quiescent restart is running. Distinct from `isDisabled`, which is also set while a
    /// readback is merely unconfirmed and no process is being replaced.
    var isRestarting: Bool

    init(isDisabled: Bool = false, disabledReason: String? = nil, isRestarting: Bool = false) {
        self.isDisabled = isDisabled
        self.disabledReason = disabledReason
        self.isRestarting = isRestarting
    }
}
