// BrowserPanel: owned by C7.6 (docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md, contract
// W1; ledger docs/doperpowers/ledgers/2026-09-09-c7.6-browser-panel.md).
//
// The Workbench's Browser tab: `WKWebView` tabs shared across the window with a URL bar, back,
// forward, reload and the Web Inspector; quick-open over the host's recent-URL feed (W8); the
// `.url` and `.pullRequest` targets on `LinkRouter` (W5); the shared tab set persisted under W6's
// `browser` key of the `workbench` namespace.
//
// Two rules shape every file here, and neither is negotiable by a later convenience.
//
// **Page content is untrusted.** No `WKScriptMessageHandler` is registered and no user script is
// injected — the chrome reads KVO properties on this side of the boundary instead — so nothing a
// page runs can call into the app, and no engine byte is ever written into a page. The only thing
// that crosses is a URL the user or a link chose, as a navigation.
//
// **X1: Workbench never imports ClaudeWire.** `ImportGraphTests` walks this directory and proves
// it; the package-wide walk is C7.1's with the manifest.
