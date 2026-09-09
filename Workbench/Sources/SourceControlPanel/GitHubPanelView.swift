// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §8, §9, §11: the branch's pull requests, their checks, the issues, and the empty states
// that say which of `gh`'s two absences this is.
import Foundation
import SwiftUI
import AfleetCore
import PanelHostAPI
import SourceControlCore

/// The GitHub tab: a scope control, the pull requests for the branch, the selected one's checks,
/// and the open issues.
///
/// **The view holds nothing.** The branch, the scope, the lists, the selection and the failure all
/// live on `GitHubModel`, which the host retains per (tab, channel). Everything drawn is read from
/// `GitHubReadout` and everything the user does is a `Control` performed on the session.
///
/// **This tab reads and never writes.** There is no merge, no approve, no close and no `gh auth`:
/// `Control.Intent`'s cases are one-for-one with `GitHubReadout.Action`, so an action that is not
/// in the inventory G4 asserts cannot be offered here (§9.2).
public struct GitHubPanelView: View {

    let session: GitHubModel

    public init(session: GitHubModel) {
        self.session = session
    }

    public var body: some View {
        let readout = session.readout
        VStack(spacing: 0) {
            header(readout)
            Divider()
            switch Self.presentation(for: readout) {
            case .emptyState(let message, let hint):
                PanelEmptyState(message: message, hint: hint)
            case .banner(let message, let hint):
                PanelBanner(message: message, hint: hint)
                Divider()
                lists(readout)
            case .none:
                lists(readout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The branch this tab is scoped to, the scope control, and *Refresh*.
    @ViewBuilder
    private func header(_ readout: GitHubReadout) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: PanelTabID.github.defaultSystemImage)
                    .foregroundStyle(.secondary)
                Text(Self.branchLabel(readout)).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                if readout.isLoading { ProgressView().controlSize(.small) }
                ForEach(Self.toolbarControls(readout), id: \.self) { control in
                    Button(control.label) { perform(control) }
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.scopeControls(readout), id: \.self) { control in
                    Button(control.label) { perform(control) }
                        .buttonStyle(.bordered)
                        .tint(Self.isCurrent(control, readout) ? .accentColor : nil)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func lists(_ readout: GitHubReadout) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pullRequests(readout)
                issues(readout)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func pullRequests(_ readout: GitHubReadout) -> some View {
        let rows = Self.pullRequestPresentations(for: readout)
        SectionHeading(text: rows.count == 1 ? "1 pull request"
                                             : "\(rows.count) pull requests")
        if rows.isEmpty, readout.hasRead {
            Text("No open pull requests.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        ForEach(rows, id: \.number) { row in
            let select = Self.control(forSelecting: row.number)
            Button {
                perform(select)
            } label: {
                PullRequestRow(row: row, open: Self.control(forOpening: row.number)) { control, destination in
                    perform(control, from: destination)
                }
            }
            .buttonStyle(.plain)
            .background(row.isSelected ? Color.accentColor.opacity(0.15) : .clear)
            if row.isSelected {
                checks(readout)
            }
        }
    }

    /// The selected pull request's checks, in the order `gh` printed them.
    @ViewBuilder
    private func checks(_ readout: GitHubReadout) -> some View {
        let rows = Self.checkPresentations(for: readout)
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text("No checks were reported for this pull request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { check in
                HStack(spacing: 6) {
                    Text(check.state).font(.caption2)
                        .foregroundStyle(Self.colour(of: check.tone))
                        .frame(width: 60, alignment: .leading)
                    Text(check.name).font(.caption).lineLimit(1)
                    if let workflow = check.workflow {
                        Text(workflow).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func issues(_ readout: GitHubReadout) -> some View {
        let rows = Self.issuePresentations(for: readout)
        if !rows.isEmpty {
            Divider().padding(.vertical, 4)
            SectionHeading(text: rows.count == 1 ? "1 open issue" : "\(rows.count) open issues")
            ForEach(rows, id: \.number) { issue in
                HStack(spacing: 6) {
                    Text("#\(issue.number)").font(.caption).monospaced()
                        .foregroundStyle(.secondary)
                    Text(issue.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(issue.author).font(.caption).foregroundStyle(.secondary)
                    Text(issue.relativeDate).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
        }
    }

    private func perform(_ control: Control, from destination: LinkDestination = .currentPanel) {
        Task { await control.perform(on: session, from: destination) }
    }

    // MARK: - what the header says

    static func branchLabel(_ readout: GitHubReadout) -> String {
        if let branch = readout.branch { return branch }
        // Detached `HEAD` has no branch to scope a list to, and the header says so rather than
        // leaving the line blank over a list that is quietly unscoped.
        return readout.isDetachedHead ? "Detached HEAD" : PanelTabID.github.defaultTitle
    }

    static func isCurrent(_ control: Control, _ readout: GitHubReadout) -> Bool {
        switch control.intent {
        case .scope(let scope): return scope == readout.scope
        default: return false
        }
    }

    // MARK: - the panel's own area (root spec §10)

    typealias NoticePresentation = PanelNoticePresentation

    static func presentation(for readout: GitHubReadout) -> NoticePresentation {
        presentation(for: readout.notice)
    }

    static func presentation(for notice: GitHubReadout.Notice?) -> NoticePresentation {
        guard let notice else { return .none }
        switch notice.placement {
        case .emptyState: return .emptyState(message: notice.message, hint: notice.hint)
        case .row: return .banner(message: notice.message, hint: notice.hint)
        }
    }

    // MARK: - the rows, as values

    /// How a badge is drawn, as a named tone rather than a colour, so that "these two are
    /// distinguishable" is a thing a test can assert.
    enum Tone: Hashable {
        case positive
        case negative
        case running
        /// Read, and there is nothing to report. Deliberately not `positive`: a pull request with
        /// no checks is not a pull request whose checks passed.
        case neutral
        /// A bucket `gh` reported that this panel does not name.
        case unknown
        /// Nobody has asked yet.
        case unread
    }

    static func colour(of tone: Tone) -> Color {
        switch tone {
        case .positive: .green
        case .negative: .red
        case .running: .orange
        case .neutral: .secondary
        case .unknown: .purple
        case .unread: .secondary
        }
    }

    /// What a row says about its checks.
    ///
    /// `isRollup` is the load-bearing field: a row whose checks have not been read must not draw a
    /// rollup at all, because a badge that said "passing" for checks nobody asked about is the
    /// failure `ChecksState` exists to prevent (Design §8).
    struct Badge: Hashable {
        let text: String
        let tone: Tone
        let isRollup: Bool
    }

    static func badge(for checks: GitHubReadout.ChecksState) -> Badge {
        switch checks {
        case .notRead:
            return Badge(text: checks.label, tone: .unread, isRollup: false)
        case .read(let rollup):
            // The words are the readout's, never this view's: a test asserting on the readout is
            // asserting on what the user reads.
            return Badge(text: rollup.label, tone: tone(of: rollup), isRollup: true)
        }
    }

    static func tone(of rollup: CheckRollup) -> Tone {
        switch rollup {
        case .none: .neutral
        case .pending: .running
        case .failing: .negative
        case .passing: .positive
        case .unknown: .unknown
        }
    }

    struct PullRequestPresentation: Hashable {
        let number: Int
        let title: String
        let author: String
        let isDraft: Bool
        let reviewDecision: String
        let labels: [String]
        let badge: Badge
        let isSelected: Bool
    }

    struct CheckPresentation: Hashable {
        let name: String
        let workflow: String?
        /// The bucket in this panel's own words, never the string `gh` printed (§6.3).
        let state: String
        let tone: Tone
    }

    struct IssuePresentation: Hashable {
        let number: Int
        let title: String
        let author: String
        let labels: [String]
        let relativeDate: String
    }

    static func pullRequestPresentations(for readout: GitHubReadout)
        -> [PullRequestPresentation] {
        readout.pullRequests.map { row in
            PullRequestPresentation(number: row.number, title: row.title, author: row.author,
                                    isDraft: row.isDraft, reviewDecision: row.reviewDecision,
                                    labels: row.labels, badge: badge(for: row.checks),
                                    isSelected: row.isSelected)
        }
    }

    static func checkPresentations(for readout: GitHubReadout) -> [CheckPresentation] {
        readout.selectedChecks.map {
            CheckPresentation(name: $0.name, workflow: $0.workflow, state: $0.bucket.label,
                              tone: tone(of: $0.bucket))
        }
    }

    static func tone(of bucket: CheckBucket) -> Tone {
        switch bucket {
        case .passing: .positive
        case .failing: .negative
        case .pending: .running
        case .skipped: .neutral
        case .unrecognised: .unknown
        }
    }

    static func issuePresentations(for readout: GitHubReadout) -> [IssuePresentation] {
        readout.issues.map {
            IssuePresentation(number: $0.number, title: $0.title, author: $0.author,
                              labels: $0.labels,
                              relativeDate: SourceControlPanelView.relativeDate($0.updatedAt))
        }
    }

    // MARK: - the controls, and the one door to the session (G4)

    /// One interactive control this tab offers.
    ///
    /// Every control is built by one of the four functions below and `perform` is the only place
    /// this file calls the session, which is what makes G4's view-layer clause an assertion about
    /// a surface rather than a review of a body.
    struct Control: Hashable {
        enum Intent: Hashable {
            case refresh
            case scope(GitHubModel.Scope)
            case selectPullRequest(Int)
            case openPullRequest(Int)
        }

        let action: GitHubReadout.Action
        let label: String
        let intent: Intent

        func perform(on session: GitHubModel,
                     from destination: LinkDestination = .currentPanel) async {
            switch intent {
            case .refresh:
                await session.refresh()
            case .scope(let scope):
                await session.select(scope: scope)
            case .selectPullRequest(let number):
                await session.select(pullRequest: number)
            case .openPullRequest(let number):
                // `.pullRequest(number)` and nothing else: no URL is built here and no remote is
                // parsed — the Browser's resolver turns a number into a page (Design §9).
                await session.open(pullRequest: number, from: destination)
            }
        }
    }

    static func toolbarControls(_ readout: GitHubReadout) -> [Control] {
        [Control(action: .refresh, label: "Refresh", intent: .refresh)]
    }

    static func scopeControls(_ readout: GitHubReadout) -> [Control] {
        [Control(action: .scopeToBranch, label: "This branch", intent: .scope(.branch)),
         Control(action: .scopeToAllOpen, label: "All open", intent: .scope(.allOpen))]
    }

    static func control(forSelecting number: Int) -> Control {
        Control(action: .selectPullRequest, label: "#\(number)",
                intent: .selectPullRequest(number))
    }

    static func control(forOpening number: Int) -> Control {
        Control(action: .openPullRequest, label: "Open #\(number)",
                intent: .openPullRequest(number))
    }

    /// Every control this view offers for `readout`. The body builds its buttons from the same
    /// four functions, so this is the surface and not a description of one.
    static func controls(for readout: GitHubReadout) -> [Control] {
        var controls = toolbarControls(readout) + scopeControls(readout)
        for row in readout.pullRequests {
            controls.append(control(forSelecting: row.number))
            controls.append(control(forOpening: row.number))
        }
        return controls
    }
}

// MARK: - the rows

private struct SectionHeading: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

private struct PullRequestRow: View {

    let row: GitHubPanelView.PullRequestPresentation
    let open: GitHubPanelView.Control
    let perform: (GitHubPanelView.Control, LinkDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("#\(row.number)").font(.caption).monospaced()
                    .foregroundStyle(.secondary)
                Text(row.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if row.isDraft {
                    Text("Draft").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 3))
                }
                Spacer(minLength: 6)
                Button(open.label) { perform(open, .currentPanel) }
                    .buttonStyle(.link)
                    .modifier(GitHubCommandClick { perform(open, .newWindow) })
            }
            HStack(spacing: 6) {
                Text(row.badge.text)
                    .font(.caption2)
                    .foregroundStyle(GitHubPanelView.colour(of: row.badge.tone))
                Text(row.author).font(.caption).foregroundStyle(.secondary)
                Text(row.reviewDecision).font(.caption).foregroundStyle(.secondary)
                ForEach(row.labels, id: \.self) { label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 3))
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

/// Cmd-click asks for a window of its own (§9.4); the Browser's target declines the pop-out and
/// opens the page, which is its decision and not this tab's.
private struct GitHubCommandClick: ViewModifier {

    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().modifiers(.command).onEnded(action))
    }
}
