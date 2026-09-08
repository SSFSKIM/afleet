import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The channel header's menus (spec C6.2 *The header's menus and actions*).
///
/// Thin over `ChannelHeaderActionsModel`: it draws the pickers, two menus and whatever the last
/// action had to say, and it decides nothing. **Tracker 74's rule is drawn rather than disabled** —
/// a read-only row gets `readOnlyReason` in place of the actions, so there is no menu of things
/// afleet must never do to a teammate's session for a user to open.
///
/// Presentation is advisory (spec *Design inheritance*); which actions exist and what gates them
/// is not.
struct ChannelHeaderMenus: View {

    @Bindable var model: ChannelHeaderActionsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.offersOwnedActions {
                SettingPickersView(model: model.pickers)
                channelMenu
                extensionsMenu
            } else if let reason = model.readOnlyExplanation {
                Label(reason, systemImage: "eye")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .sheet(isPresented: $model.isShowingBypassDisclaimer) { BypassDisclaimerSheet(model: model) }
        .popover(isPresented: $model.isShowingMCP) { MCPServerList(servers: model.mcpServers) }
    }

    /// The channel's own lifecycle: fork, hand off, stop.
    private var channelMenu: some View {
        Menu("Channel") {
            Button("Fork") { Task { await model.fork() } }
            Button("Send to Background…") { Task { await model.sendToBackground() } }
            Button("Open in Terminal") { Task { await model.openInTerminal() } }
            Divider()
            Button("Rename…") { model.isRenaming = true }
            Divider()
            Button("Stop Everything…", role: .destructive) { Task { await model.stopEverything() } }
            Button("Background All…") { Task { await model.backgroundAll() } }
        }
        .sheet(isPresented: $model.isRenaming) { RenameSheet(model: model) }
    }

    /// What the engine loaded: MCP servers, skills, plugins — and the one per-channel launch flag
    /// this header toggles.
    private var extensionsMenu: some View {
        Menu("Extensions") {
            Button("MCP Servers…") { Task { await model.showMCPServers() } }
            Divider()
            Button("Reload Skills") { Task { await model.reloadSkills() } }
            Button("Reload Plugins") { Task { await model.reloadPlugins() } }
            Divider()
            Toggle("Prompt Suggestions", isOn: Binding(get: { model.promptSuggestionsEnabled },
                                                       set: { on in Task { await model.setPromptSuggestions(on) } }))
        }
    }
}

/// `mcp_status`, rendered: the servers the strategy answered with and their status, and nothing
/// derived from either.
struct MCPServerList: View {

    let servers: [MCPPopover.Server]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if servers.isEmpty {
                Text("No MCP servers.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(servers, id: \.name) { server in
                HStack(spacing: 6) {
                    Text(server.name).font(.callout)
                    Text(server.status).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

/// *Rename*. The confirmation is the **absence of an error**: `rename_session` answers a plain
/// success with no body at all, so there is no readback to wait for and a sheet that waited for one
/// would never close.
struct RenameSheet: View {

    @Bindable var model: ChannelHeaderActionsModel
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename this conversation").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.isRenaming = false }
                Button("Rename") {
                    model.isRenaming = false
                    Task { await model.rename(to: title) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// §8.6's disclaimer, shown on the **first** selection of the bypass mode.
///
/// *Decline* leaves the mode unavailable, restarts nothing and writes nothing. *Accept* runs the
/// three steps of `BypassGate.acceptBypassMode()` in order.
struct BypassDisclaimerSheet: View {

    @Bindable var model: ChannelHeaderActionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skip all permission prompts?").font(.headline)
            Text("""
                In this mode the engine runs every tool without asking, including commands that \
                change files and reach the network. afleet restarts this channel to turn it on, and \
                remembers the acceptance for later channels.
                """)
            .frame(maxWidth: 420, alignment: .leading)
            HStack {
                Spacer()
                Button("Decline", role: .cancel) { model.declineBypassMode() }
                Button("Accept", role: .destructive) { Task { await model.acceptBypassMode() } }
            }
        }
        .padding(16)
    }
}
