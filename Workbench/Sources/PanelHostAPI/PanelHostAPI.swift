// PanelHostAPI: owned by C5 (docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md, contract W1).
//
// Contract X7: the panel-tab host protocol. The conversation surface (C6) and every Workbench
// panel leaf (C7.4 through C7.7) plug into the declarations in this target, so the names here
// are a published interface and change only with a Revision Note on the C7 spec.
//
// The target is protocols and value types only. It ships no conformance, no concrete type and
// no default implementation; C5's app shell and the C7 leaves own every implementation.
//
// Its whole shape rests on one claim, which `ImportGraphTests` is written to prove: the panel
// contract can be expressed without naming a type defined in `ClaudeWire`, so Workbench never
// imports it (parent contract X1). That is why `ChannelContext` carries capabilities — a scoped
// store, a link router, a recent-URL feed and a pane-exit reporter — rather than FleetKit's
// `LifecycleAPI`, whose signature names `WireEvent`. Withholding the lifecycle object is also
// what stops a panel from spawning a `claude` process on its own initiative.
//
// The imports allowed under this target are Foundation, SwiftUI, AfleetCore and FleetKit.
