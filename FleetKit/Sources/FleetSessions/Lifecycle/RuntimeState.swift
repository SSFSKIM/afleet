import Foundation
import AfleetCore
import ClaudeWire

/// Which answer or frame sets which field of `SessionRuntimeState`.
///
/// The record exists because `--resume` restores the conversation and nothing else: the permission mode, the model,
/// the effort, the output style and every `apply_flag_settings` value are process-local, so a restart has to carry
/// them itself. What it carries is what the channel is *running* — every value here arrived from an engine answer or
/// an engine frame — and never what the channel was opened with.
public enum RuntimeStateUpdater {

    /// The wire subtype a spec goes out under. `RawControlRequest` carries its own; every other spec's is its static
    /// one. The same rule `OutboundEnvelope.encode` applies, so what the updater switches on is what the engine saw.
    public static func subtype<R: ControlRequestSpec>(of request: R) -> String {
        (request as? RawControlRequest)?.wireSubtype ?? R.subtype
    }

    /// One control answer. The *request* is as much of the record as the answer is: `set_model` and
    /// `set_permission_mode` are answered with a bare success, and `apply_flag_settings` too, so for those the value
    /// the host asked for is the only evidence of what the engine now holds.
    public static func apply<R: ControlRequestSpec>(answer: R.Response, for request: R,
                                                    to state: inout SessionRuntimeState) {
        apply(subtype: subtype(of: request), payload: request.payload,
              answer: (answer as? JSONValue) ?? .object([:]), to: &state)
    }

    /// The same rule over the wire values, so a test can drive the table without building a spec per row.
    public static func apply(subtype: String, payload: JSONValue, answer: JSONValue,
                             to state: inout SessionRuntimeState) {
        switch subtype {
        case SetModel.subtype:
            // Present-and-null is the engine's "back to the default" and clears the value; *absent* is not a
            // statement about the model at all and leaves it alone.
            if let asked = payload["model"] { state.model = asked.stringValue }
        case SetPermissionMode.subtype:
            if let mode = payload["mode"]?.stringValue.flatMap(PermissionMode.init(rawValue:)) {
                state.permissionMode = mode
            }
        case ApplyFlagSettings.subtype:
            // The engine answers a bare success, so the payload is the record. Later values win, and the union of
            // every payload is what a restart re-sends.
            for (key, value) in payload["settings"]?.objectValue ?? [:] { state.flagSettings[key] = value }
        case GetSettings.subtype:
            let applied = answer["applied"] ?? .object([:])
            if let model = applied["model"]?.stringValue { state.model = model }
            if let effort = applied["effort"]?.stringValue { state.effort = effort }
            if let style = applied["output_style"]?.stringValue { state.outputStyle = style }
        case SetCwd.subtype:
            // `{status: "ok", cwd: <resolved>}` is the accepted answer; a `needs_trust` answer carries no `cwd` and
            // changes nothing (shape from the `control-shapes` recording).
            if let path = answer["cwd"]?.stringValue { state.cwd = URL(fileURLWithPath: path) }
        case "add_directory":
            // Accepted: the answer came back rather than throwing. The directory is the one the host asked for.
            // `directory` is the key FleetKit sends. The corpus records no `add_directory` exchange at all — it
            // is a cloud-container staging call with no local headless equivalent — so the request shape is the
            // host's own and this reads back exactly what the host asked for rather than guessing at alternatives.
            if let asked = payload["directory"]?.stringValue {
                let url = URL(fileURLWithPath: asked)
                if !state.addDirectories.contains(url) { state.addDirectories.append(url) }
            }
        default:
            break
        }
    }

    /// Every engine frame that carries a value the restart has to reproduce. `fast_mode_state` rides on the
    /// initialize response and on `result`, and on no other frame.
    public static func apply(frame: Frame, to state: inout SessionRuntimeState, seededFromInit: inout Bool) {
        switch frame {
        case .result(let result):
            if let value = result.fastModeState { state.fastModeObserved = value == "on" }
        case .system(.initialize(let initFrame)):
            if let value = initFrame.fastModeState { state.fastModeObserved = value == "on" }
            guard !seededFromInit else { return }
            seededFromInit = true
            state.model = initFrame.model
            state.permissionMode = PermissionMode(rawValue: initFrame.permissionMode) ?? state.permissionMode
            state.outputStyle = initFrame.outputStyle
            state.cwd = URL(fileURLWithPath: initFrame.cwd)
            // `system/init.agent` is absent on every recorded launch, `--agent` ones included (parent §7.4), so this
            // reads whatever an engine that grows the key would send and leaves the value alone until one does.
            if let agent = initFrame.additional["agent"]?.stringValue { state.agent = agent }
        default:
            break
        }
    }

    /// What the handshake seeds. `fastModeObserved` is an observation and is always taken from the newest report;
    /// the rest are *seeds* and never overwrite a value the host has since set, because a stale engine report must
    /// not silently undo a `/model` or a `/permissions` the user asked for.
    public static func apply(handshake: InitializeResponse, to state: inout SessionRuntimeState) {
        if let value = handshake.fastModeState { state.fastModeObserved = value == "on" }
        if state.model == nil { state.model = handshake.currentModel }
        if state.permissionMode == nil { state.permissionMode = handshake.currentPermissionMode }
        if state.outputStyle == nil { state.outputStyle = handshake.outputStyle }
    }
}

/// The restart's readbacks: which value is verified against which source, and in one fixed order.
public enum Readback {

    /// The names of the settings that did not survive the relaunch, in a fixed order and empty when every one did.
    ///
    /// Each value is read from the source that carries it and from no other: `model` and `effort` from
    /// `get_settings.applied` (the only answer that reports them), the permission mode and the output style from the
    /// new handshake, every `apply_flag_settings` key from `effective_keys`. Fast mode has two sources and they must
    /// not be confused: when the host applied it the key is in `flagSettings` and `effective_keys` is the whole
    /// check — the handshake is not consulted, because the engine reports a host toggle lazily and a correct restart
    /// would fail against it. Only when fast mode was *observed* and never applied does the new handshake's
    /// `fast_mode_state` answer for it.
    public static func verify(snapshot: RestartSnapshot, handshake: InitializeResponse,
                              settingsApplied: JSONValue, effectiveKeys: [String]) -> [String] {
        var failed: [String] = []
        if let model = snapshot.model, settingsApplied["model"]?.stringValue != model { failed.append("model") }
        if let effort = snapshot.effort, settingsApplied["effort"]?.stringValue != effort { failed.append("effort") }
        if let mode = snapshot.permissionMode, handshake.currentPermissionMode != mode {
            failed.append("permissionMode")
        }
        if let style = snapshot.outputStyle, handshake.outputStyle != style { failed.append("outputStyle") }
        let present = Set(effectiveKeys)
        for key in snapshot.flagSettings.keys.sorted() where !present.contains(key) {
            failed.append("flagSettings.\(key)")
        }
        if snapshot.flagSettings["fastMode"] == nil, let observed = snapshot.fastModeObserved,
           (handshake.fastModeState == "on") != observed {
            failed.append("fastMode")
        }
        return failed
    }
}
