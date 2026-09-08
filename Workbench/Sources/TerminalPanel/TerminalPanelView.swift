// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import SwiftUI

/// The Terminal tab's whole view: the pane bar, the selected pane, and the question a live pane
/// asks before it closes.
///
/// The views here are deliberately thin. Every fact one of them draws comes from ``PaneReadout``
/// or from the session, so a test on those values is a test on what the window shows — a rendered
/// `Text` is not an assertion.
struct TerminalPanelView: View {

    let session: TerminalPanelSession

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(session: session)
            Divider()
            if let pane = session.selectedPane {
                PaneView(session: session, pane: pane)
            } else {
                noPanes
            }
            if let confirmation = session.pendingClose {
                Divider()
                CloseConfirmationBar(session: session, confirmation: confirmation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Closing the last pane leaves none. That is a state the tab renders rather than one the
    /// session papers over by opening another pane nobody asked for.
    private var noPanes: some View {
        VStack(spacing: 10) {
            Text("No panes in this channel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("New shell pane") { session.openShellPane() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The pane stack, as a bar: one entry per pane, labelled with the pane's purpose in words, and a
/// `+` for a new shell pane. No reordering and no splits — panes are a stack (spec Design §10).
private struct PaneBar: View {

    let session: TerminalPanelSession

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(session.panes.enumerated()), id: \.offset) { index, pane in
                entry(index: index, pane: pane)
            }
            Spacer(minLength: 0)
            Button {
                session.openShellPane()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New shell pane")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func entry(index: Int, pane: TerminalPane) -> some View {
        let readout = PaneReadout(pane: pane)
        let isSelected = session.selectedIndex == index
        return HStack(spacing: 6) {
            Button {
                session.select(index)
            } label: {
                Text(readout.purpose)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            Button {
                Task { await session.requestClose(pane) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Close pane")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

/// One pane: its renderer, and — once its child is anything but running — what happened to it.
private struct PaneView: View {

    let session: TerminalPanelSession
    let pane: TerminalPane

    var body: some View {
        let readout = PaneReadout(pane: pane)
        VStack(spacing: 0) {
            PaneSurfaceHost(pane: pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if readout.status != .running {
                Divider()
                PaneStatusBar(session: session, pane: pane, readout: readout)
            }
        }
    }
}

/// What the pane says about itself, and the buttons it offers — both read straight off the
/// readout, so the panel offers *Restart pane* exactly where ``PaneReadout`` says it is honest.
private struct PaneStatusBar: View {

    let session: TerminalPanelSession
    let pane: TerminalPane
    let readout: PaneReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.purpose).font(.caption.weight(.semibold))
                Text(readout.summary).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach(readout.actions, id: \.self) { action in
                    button(for: action)
                }
            }
            if let detail = readout.failureDetail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // A `PaneRequest` pane offers no restart, so what it can honestly do is say where a
            // fresh request comes from (spec Design §6).
            if let origin = readout.newPaneOrigin {
                Text(origin).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func button(for action: PaneAction) -> some View {
        switch action {
        case .restart:
            Button("Restart pane") { Task { await session.restart(pane) } }
        case .resume:
            Button("Continue") { Task { await pane.continueStopped() } }
        case .close:
            Button("Close pane") { Task { await session.requestClose(pane) } }
        }
    }
}

/// The question, and its two answers. Not an `NSAlert`: the confirmation is session state, which
/// is what lets both answers be given headlessly (spec Design §2).
private struct CloseConfirmationBar: View {

    let session: TerminalPanelSession
    let confirmation: PaneCloseConfirmation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(confirmation.question).font(.callout)
            Spacer(minLength: 0)
            Button("Keep running") { session.cancelPendingClose() }
            Button("Close pane") { Task { await session.confirmPendingClose() } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
