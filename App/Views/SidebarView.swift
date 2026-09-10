import SwiftUI
import AfleetCore
import FleetKit

/// The fleet browser (spec §4): Activity, then one section per project, then the projects the
/// thirty-day default hides, then the background roster, then the archive.
///
/// Every list here is a `List` section rather than a `ScrollView` of a `VStack`, because a `List`
/// is lazy and this view is asked to draw a corpus of three thousand rows. The decisions the view
/// renders — which rows the thirty-day window hides, how many, which projects vanish entirely —
/// are `SidebarOutline`'s, so nothing below computes a rule.
struct SidebarView: View {

    @Bindable var browser: FleetBrowserModel
    @Bindable var shell: ShellModel

    var body: some View {
        List(selection: $shell.listSelection) {
            Label("Activity", systemImage: "bell")
                .tag(ShellModel.Focus.activity)

            ForEach(SidebarOutline.recentSections(browser.sections)) { section in
                projectSection(section)
            }

            allProjectsSection
            backgroundSection
            archivedSection
        }
        .listStyle(.sidebar)
        .onChange(of: shell.focus) { _, focus in
            if let session = focus.session { browser.select(session) }
        }
        .task { await browser.refreshBackground() }
        // §8.2's *New channel*, presented here and not in `RootView`, which Task 5 closed: this is
        // the view that is on screen for the whole workspace route, and the one whose section
        // headers raise the other entry point. Both entries write `ShellModel.newChannelRequest`,
        // so the global item in the app's command group has somewhere to put a press that has no
        // view to reach.
        .sheet(item: Binding(get: { shell.newChannelRequest },
                             set: { if $0 == nil { shell.dismissNewChannel() } })) { request in
            NewChannelSheet(request: request) { shell.dismissNewChannel() }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private func projectSection(_ section: ProjectSection) -> some View {
        let expanded = shell.expandedProjects.contains(section.id)
        let hidden = SidebarOutline.hiddenCount(in: section)
        Section {
            ForEach(SidebarOutline.visibleRows(section.rows, expanded: expanded)) { row in
                ChannelRowView(row: row)
                    .tag(ShellModel.Focus.channel(row.id))
            }
            ForEach(section.worktrees) { worktree in
                DisclosureGroup {
                    ForEach(SidebarOutline.visibleRows(worktree.rows, expanded: expanded)) { row in
                        ChannelRowView(row: row)
                            .tag(ShellModel.Focus.channel(row.id))
                    }
                } label: {
                    Label(worktree.title, systemImage: "arrow.triangle.branch")
                        .font(.callout)
                }
            }
            if hidden > 0 {
                Button(expanded ? "Show recent only" : "Show all (\(hidden))") {
                    shell.toggleShowAll(section.id)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            ProjectSectionHeader(section: section, shell: shell)
        }
    }

    @ViewBuilder
    private var allProjectsSection: some View {
        let older = SidebarOutline.olderSections(browser.sections)
        if !older.isEmpty {
            Section("All projects") {
                DisclosureGroup(isExpanded: $shell.showsAllProjects) {
                    ForEach(older) { section in
                        ForEach(section.allRows) { row in
                            ChannelRowView(row: row)
                                .tag(ShellModel.Focus.channel(row.id))
                        }
                    }
                } label: {
                    Text("\(older.count) project\(older.count == 1 ? "" : "s") with nothing in the last 30 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundSection: some View {
        if !browser.background.isEmpty {
            Section("Background") {
                ForEach(browser.background, id: \.short) { job in
                    JobRowView(job: job,
                               banner: browser.jobBanners[job.short.rawValue],
                               adopt: { Task { await browser.adopt(job) } },
                               attach: { Task { await Self.openJobPane(job, verb: .attach,
                                                                       browser: browser,
                                                                       shell: shell) } },
                               logs: { Task { await Self.openJobPane(job, verb: .logs,
                                                                     browser: browser,
                                                                     shell: shell) } },
                               stop: { Task { await browser.stop(job) } })
                }
            }
        }
    }

    /// X5's two job panes, *Attach* and *Logs*, as one verb over two requests.
    ///
    /// **A static function taking its collaborators**, the shape `PanelColumnView
    /// .resolvePendingPanelIndex` already has here: the test calls exactly what the row calls, with
    /// no window and no `List` around it. Logic inside the row's closure would be reachable only by
    /// rendering the sidebar.
    ///
    /// **The channel is named before X5 is asked.** `claude attach` starts a client, and starting
    /// one for a pane that could never be placed leaves a child running for a screen nobody will
    /// see; naming first means the row refuses before anything is spawned.
    ///
    /// **And the host's refusal is a banner too** (§10). `run(_:for:)` throws when no Terminal leaf
    /// holds a runner or when the host cannot resolve the named channel — both are things the user
    /// should read on the row that asked, not errors travelling into a channel.
    ///
    /// **Naming a channel means making it resolvable.** The host can build a context only for a
    /// channel it has been given a working directory for, and it forgets both when LRU pressure
    /// evicts one — so a job in a channel no window has shown, or has stopped showing, would be
    /// refused for want of a directory the caller is holding. This is the caller, so it names that
    /// too. With no directory to name, the host's refusal stands exactly as it did.
    /// **And naming a channel means showing it** (ruled 2026-09-09; tracker 384). A row acts on the
    /// channel that row is about, so the window goes there: without this the host selected the
    /// Terminal tab while the panel column went on deriving its channel from `shell.focus`, and
    /// *Attach* started a pane in a channel nobody was looking at. Item 15 says *Attach* shows the
    /// job's screen, and an invisible pane is not that.
    ///
    /// **Two conditions on that move, and both are about what the user would be shown.** It happens
    /// only *after* X5 has answered, because a refusal moves nobody: the window would otherwise be
    /// standing in a channel where nothing opened, to read a banner on the row it was sent from.
    /// And it happens only for a channel the browser has a **row** for, because `PanelColumnView`
    /// resolves the channel it draws through that row — selecting a session with none leaves the
    /// column on its pick-a-channel placeholder, which is the invisible pane again. It still
    /// happens **before** `panels.run`, so the window is already there when the client's first
    /// bytes arrive.
    static func openJobPane(_ job: JobEntry, verb: JobPaneVerb,
                            browser: FleetBrowserModel, shell: ShellModel) async {
        let panels = shell.panels
        guard let channel = browser.paneChannel(for: job, inView: panels.selectedChannel) else { return }
        if panels.context(for: channel) == nil, let cwd = browser.paneCWD(for: job, in: channel) {
            _ = panels.context(for: channel, cwd: cwd)
        }
        let request: PaneRequest?
        switch verb {
        case .attach: request = await browser.attach(job)
        case .logs: request = await browser.logs(job)
        }
        // A refusal from X5 has already been written onto the row by the browser.
        guard let request else { return }
        if browser.row(channel.session) != nil { shell.select(channel.session) }
        do {
            try await panels.run(request, for: channel)
        } catch {
            browser.noteJobFailure(job, error)
        }
    }

    // MARK: - Archived

    @ViewBuilder
    private var archivedSection: some View {
        if !browser.archived.isEmpty {
            Section("Archived") {
                ForEach(browser.archived) { row in
                    ChannelRowView(row: row)
                        .tag(ShellModel.Focus.channel(row.id))
                        .foregroundStyle(.secondary)
                        .opacity(0.65)
                }
            }
        }
    }
}

/// One project section's header: the pin, the title, and §8.2's *New channel…* item pre-filled with
/// the section's own root.
///
/// **A view of its own, not four lines inside `SidebarView.body`**, on the precedent
/// `SidebarView.openJobPane` and `PanelColumnView.resolvePendingPanelIndex` set here: the press is
/// the only thing connecting the header to the sheet, and an item whose action named a different
/// project would leave every model-level assertion green. `SidebarView.body` builds a
/// `List(selection:)` a test cannot evaluate, so this is the value a test can.
struct ProjectSectionHeader: View {

    let section: ProjectSection
    let shell: ShellModel

    /// The item's accessible name, which names the project: two headers' items are two actions and
    /// a shared label would leave a test — and VoiceOver — unable to tell them apart.
    static func itemLabel(_ section: ProjectSection) -> String { "New channel in \(section.title)" }

    var body: some View {
        HStack(spacing: 4) {
            if section.isPinned { Image(systemName: "pin.fill").font(.caption2) }
            Text(section.title)
            Spacer(minLength: 4)
            // A button rather than a context menu: the header is the affordance §8.2 names, and a
            // menu on a `List` section header is not reliably reachable.
            // A `Label` with the icon-only style rather than a bare `Image`: the item shows as the
            // plus §8.2 asks for and still carries its name, so VoiceOver reads which project it is
            // for and the menu bar's own *New Channel…* is not the only named way in.
            Button(Self.itemLabel(section)) {
                shell.presentNewChannel(root: section.root)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .font(.caption2)
            .help(Self.itemLabel(section))
        }
    }
}

/// One channel. The origin glyph on the left, the title and presence in the middle, the pending
/// decision count on the right.
struct ChannelRowView: View {

    let row: ChannelRow

    /// Activity's badge for this channel (spec §6, G2b), read through the environment because
    /// `RootView` is closed and the sidebar is four levels below it. Optional: a preview or a test
    /// that renders one row in isolation has no `AppModel`, and a row without a badge is a row.
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: (row.originGlyph ?? .archived).systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityLabel(Text((row.originGlyph ?? .archived).rawValue))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                    .italic(row.isProvisional)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let banner = row.banner {
                    Text(banner.text)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            // The count is Activity's, not `row.pendingDecisionCount`: a decision the user has
            // already looked at is still pending, and a red count that survived looking at it
            // would ask them to act on something they have acted on. Both halves clear together
            // when the channel is selected, and both come back when the next thing arrives.
            if badge.count > 0 {
                Text("\(badge.count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text("\(badge.count) waiting decisions"))
            }
            if badge.isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("unread"))
            }
        }
    }

    private var badge: ChannelBadge { app?.activity?.badge(for: row.id) ?? .none }

    /// Presence when the channel is live, the transcript's own preview when it is not. A row with
    /// no `ChannelState` has no presence to report and saying "Idle" would be an invention.
    private var subtitle: String? {
        if let presence = row.presence, let text = Self.presenceText(presence) { return text }
        return row.preview.isEmpty ? nil : row.preview
    }

    private var tint: Color {
        switch row.originGlyph {
        case .ready: .green
        case .connecting: .yellow
        case .contended: .orange
        case .usersTerminal, .ownTerminalTab: .blue
        case .backgroundJob: .purple
        case .dormant, .archived, nil: .secondary
        }
    }

    static func presenceText(_ presence: Presence) -> String? {
        switch presence {
        case .idle: "Idle"
        case .busy: "Working"
        case .waiting(let what): what.map { "Waiting for \($0)" } ?? "Waiting"
        case .unknown: nil
        }
    }
}

/// Which of X5's two job panes a row asked for. Two cases rather than a boolean, because §9.5 and
/// §17 C7 name them as two affordances and the sentence a refusal writes is the row's either way.
enum JobPaneVerb {
    case attach
    case logs
}

/// One background job, with the actions spec §4 and §9.5 name.
struct JobRowView: View {

    let job: JobEntry
    let banner: String?
    let adopt: () -> Void
    let attach: () -> Void
    let logs: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: OriginGlyph.backgroundJob.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.purple)
                Text(job.name ?? job.kind).lineLimit(1)
                Spacer(minLength: 4)
                Text(job.state).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Adopt", action: adopt).disabled(job.sessionID == nil)
                Button("Attach", action: attach)
                Button("Logs", action: logs)
                Button("Stop", action: stop)
            }
            .buttonStyle(.link)
            .font(.caption)
            if let banner {
                Text(banner).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}
