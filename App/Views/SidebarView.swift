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
            HStack(spacing: 4) {
                if section.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                Text(section.title)
            }
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
                                                                       panels: shell.panels) } },
                               logs: { Task { await Self.openJobPane(job, verb: .logs,
                                                                     browser: browser,
                                                                     panels: shell.panels) } },
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
    static func openJobPane(_ job: JobEntry, verb: JobPaneVerb,
                            browser: FleetBrowserModel, panels: PanelHostModel) async {
        guard let channel = browser.paneChannel(for: job, inView: panels.selectedChannel) else { return }
        let request: PaneRequest?
        switch verb {
        case .attach: request = await browser.attach(job)
        case .logs: request = await browser.logs(job)
        }
        // A refusal from X5 has already been written onto the row by the browser.
        guard let request else { return }
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
