import AppKit
import PanelHostAPI
import SwiftUI
import WebKit

/// The Browser panel: a tab strip, a URL bar, the page, and the quick-open sheet (Q8, Q9, Q21).
///
/// It renders `BrowserModel`, which is shared by every surface, and one `BrowserTabSession`, which
/// is this channel's. `surface` is which of Q5's two places this instance is: the web views live in
/// exactly one of them at a time, and the other draws a short state with a control that brings them
/// back — an `NSView` has one superview, so there is no third answer that is not two browsers.
public struct BrowserPanelView: View {

    @Bindable var model: BrowserModel
    @Bindable var session: BrowserTabSession
    let surface: PanelSurface

    public init(model: BrowserModel, session: BrowserTabSession, surface: PanelSurface) {
        self.model = model
        self.session = session
        self.surface = surface
    }

    public var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(model: model)
            Divider()
            BrowserURLBar(model: model, session: session)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.restore() }
        // The pop-out lifecycle, and the whole of what connects it to the web views: a window that
        // appears takes them, and one that goes away hands them back.
        .onAppear { model.surfaceAppeared(surface) }
        .onDisappear { model.surfaceDisappeared(surface) }
        // Not `$session.isPresented`: the sheet is closed through `closeQuickOpen`, which is also
        // what cancels the feed subscription (Q8). A binding that only flipped the flag would leave
        // a channel's subscription running behind a sheet nobody can see.
        .sheet(isPresented: Binding(get: { session.isPresented },
                                    set: { if !$0 { session.closeQuickOpen() } })) {
            BrowserQuickOpenSheet(model: model, session: session)
        }
    }

    @ViewBuilder private var content: some View {
        if !model.rendersWebViews(on: surface) {
            elsewhere
        } else if let web = model.selected?.web {
            BrowserWebViewHost(webView: web.webView)
                .id(web.id)
        } else {
            empty
        }
    }

    /// Q5's consequence, stated plainly rather than papered over. It names where the pages went,
    /// which is the one thing the user needs and the one thing only the model knows.
    private var elsewhere: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(isPoppedOut ? "Showing in a Browser window"
                             : "Showing in the main window").font(.headline)
            Text("The tabs are the same ones; a page can only be drawn in one place at a time.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Bring them back here") { model.attach(to: surface) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the pages are in one of the popped-out windows rather than the main one.
    private var isPoppedOut: Bool {
        if case .poppedOutWindow = model.attachedTo { return true }
        return false
    }

    /// The last tab closed, or the panel has never had one.
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
            Text("No tabs open").font(.headline)
            Text("Open a page from the URL bar, or pick one this session has printed.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("New Tab") { model.openNewTab(url: nil) }
                Button("Recent URLs…") { session.openQuickOpen() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The tab strip

/// Title, a close control, and a `+` (Q21). Cmd-T opens a tab while the panel has focus.
///
/// **No Cmd-W override.** That closes windows on macOS, and stealing it inside a panel is the kind
/// of surprise a panel does not get to spring.
struct BrowserTabStrip: View {

    @Bindable var model: BrowserModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        item(tab)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button {
                model.openNewTab(url: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("t", modifiers: .command)
            .help("New tab")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
    }

    private func item(_ tab: BrowserLiveTab) -> some View {
        HStack(spacing: 5) {
            Text(tab.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 180)
        .background(tab.id == model.selectedID ? Color.secondary.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab.id) }
    }
}

// MARK: - The URL bar

/// Back, forward, reload, the address field, a progress line, and whatever the panel has to say
/// about a refusal.
struct BrowserURLBar: View {

    @Bindable var model: BrowserModel
    @Bindable var session: BrowserTabSession
    /// The field's own state, and never a mirror of the page: see `BrowserAddressField` for the two
    /// rules it holds and why neither of them can live in an `onChange`.
    @State private var field = BrowserAddressField()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.chrome?.canGoBack != true)
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.chrome?.canGoForward != true)
                Button {
                    // One control with two jobs, and the model decides which: while the label is
                    // an `xmark` this stops the load rather than starting it again.
                    model.reloadOrStop()
                } label: {
                    Image(systemName: model.chrome?.isLoading == true ? "xmark" : "arrow.clockwise")
                }
                .disabled(model.selected?.web == nil)
                .help(model.chrome?.isLoading == true ? "Stop" : "Reload")

                TextField("Address", text: Binding(get: { field.text },
                                                   set: { field.edited(to: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($isFocused)
                    .onSubmit {
                        let typed = field.text
                        field.submitted()
                        model.submitURLBar(typed)
                    }

                Button { session.openQuickOpen() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Recent URLs from this session")
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            // A determinate line while a page is loading, and nothing at all when one is not: an
            // idle progress view that sits at zero reads as a stuck page.
            if model.chrome?.isLoading == true {
                ProgressView(value: model.chrome?.estimatedProgress ?? 0)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
            if let message = model.urlBarMessage ?? model.notice {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            // A load that ended without a page: a quiet row and never an alert (§10). A page that
            // does not load is an ordinary thing for a browser to have happen, and the panel that
            // said nothing about it left the user looking at the page before it.
            if let message = model.loadFailureMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            // The tab-set document's own trouble: a quiet row and never an alert (§10). A newer
            // build's document refuses every write for the life of the process, and a panel that
            // presented ordinary editable tabs over it would be showing the user work that is not
            // being kept.
            if let message = model.storeErrorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            // A link the panel could not open: its own row rather than a notice, because it comes
            // with something to do about it (§10, Q2).
            if let error = model.linkError {
                VStack(alignment: .leading, spacing: 1) {
                    Text(error.message).font(.caption2)
                    if let hint = error.hint {
                        Text(hint).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
        }
        // The field follows the page except while the user is composing an address, and it is
        // seeded when it appears: this state is rebuilt on every channel switch, and a page that is
        // already settled fires neither `onChange` (B5).
        .onAppear { field.appeared(showing: model.chrome?.url ?? model.selected?.url) }
        .onChange(of: model.chrome?.url) { _, new in field.pageChanged(to: new) }
        .onChange(of: model.selectedID) { _, _ in field.tabChanged(to: model.selected?.url) }
        .onChange(of: isFocused) { _, focused in
            if !focused { field.focusEnded() }
        }
    }
}

// MARK: - Quick-open

/// The channel's recent URLs, filtered as the user types. Enter opens in the current tab,
/// Cmd-Enter in a new one (Q8).
struct BrowserQuickOpenSheet: View {

    @Bindable var model: BrowserModel
    @Bindable var session: BrowserTabSession
    /// The row the keyboard is on. The rule lives in the value type, not here: a `@State` integer
    /// moved inside a gesture is not something a test can drive, and Q8's "Enter opens the selected
    /// URL" is a rule (C2 of fix wave C).
    @State private var selection = BrowserQuickOpenSelection()

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter this session's URLs", text: $session.query)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(10)
                .onSubmit { submit(commandHeld: false) }
            Divider()
            list
            Divider()
            HStack {
                Text("Return opens in this tab · ⌘Return in a new one")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { session.closeQuickOpen() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
        }
        .frame(width: 520, height: 360)
        // The arrow keys, on the sheet rather than on the field: a single-line `TextField` keeps
        // the caret and hands these on, and the submit reads the same selection they move.
        .onKeyPress(.upArrow) {
            selection.moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            selection.moveDown(resultCount: session.results.count)
            return .handled
        }
        // The filter narrowing must not leave the highlight past the end of what it left behind.
        .onChange(of: session.results.count) { _, count in selection.resultsChanged(count: count) }
        .background {
            // The Cmd-Return half of Q8. It is a button rather than a key handler on the field
            // because a submitted `TextField` cannot report its modifiers.
            Button("") { submit(commandHeld: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder private var list: some View {
        if session.results.isEmpty {
            VStack {
                Spacer()
                Text(session.entries.isEmpty ? "This session has not printed a URL yet."
                                             : "Nothing matches.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(Array(session.results.enumerated()), id: \.element.url) { index, entry in
                Text(entry.url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .listRowBackground(index == selection.index ? Color.accentColor.opacity(0.2) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection.select(index)
                        submit(commandHeld: false)
                    }
            }
            .listStyle(.plain)
        }
    }

    private func submit(commandHeld: Bool) {
        let results = session.results
        guard let chosen = selection.chosenIndex(resultCount: results.count) else { return }
        model.open(results[chosen].url, in: .quickOpenSubmission(commandHeld: commandHeld))
        session.closeQuickOpen()
    }
}

// MARK: - The page

/// The one place a `WKWebView` reaches SwiftUI. It hands over a view the model already owns and
/// never makes one: a representable that constructed its own would be a second web view per
/// surface, which is exactly what Q5 rules out.
struct BrowserWebViewHost: NSViewRepresentable {

    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
