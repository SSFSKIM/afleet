// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §1, §4, §6, §11: the graph, the detail pane, the working-tree section, and a view that
// holds nothing the session owns.
import Foundation
import SwiftUI
import AfleetCore
import PanelHostAPI
import SourceControlCore

/// The Source Control tab: a graph column beside a detail pane.
///
/// **The view holds nothing.** The window, the lanes, the selection, the detail, the panel's own
/// area and the watch all live on `SourceControlModel`, which the host retains per (tab, channel);
/// SwiftUI discards a subtree's `@State` when the subtree unmounts, which is why X7's session
/// contract exists. Everything drawn below is read from `SourceControlReadout` and everything the
/// user does is a `Control` performed on the session.
///
/// **§9.2 is binding**: this panel is a reader. There is no staging, commit, branch, checkout,
/// stash, push or merge control here, and the only door from this file to the session is
/// `Control.perform`, whose intents are one-for-one with `SourceControlReadout.Action` — so a
/// forbidden verb cannot be offered without first being added to the inventory G4 asserts.
public struct SourceControlPanelView: View {

    let session: SourceControlModel
    var metrics = GraphMetrics()

    public init(session: SourceControlModel) {
        self.session = session
    }

    public var body: some View {
        let readout = session.readout
        HSplitView {
            historyColumn(readout)
                .frame(minWidth: 280, idealWidth: 420, maxWidth: .infinity)
            DetailPane(session: session, readout: readout)
                .frame(minWidth: 260, idealWidth: 340, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func historyColumn(_ readout: SourceControlReadout) -> some View {
        VStack(spacing: 0) {
            header(readout)
            Divider()
            switch Self.presentation(for: readout) {
            case .emptyState(let message, let hint):
                PanelEmptyState(message: message, hint: hint)
            case .banner(let message, let hint):
                PanelBanner(message: message, hint: hint)
                Divider()
                rows(readout)
            case .none:
                rows(readout)
            }
        }
    }

    /// The branch, its upstream and the one control the header carries.
    @ViewBuilder
    private func header(_ readout: SourceControlReadout) -> some View {
        HStack(spacing: 8) {
            Image(systemName: PanelTabID.sourceControl.defaultSystemImage)
                .foregroundStyle(.secondary)
            Text(Self.branchLabel(readout)).font(.headline).lineLimit(1)
            if let tracking = Self.trackingLabel(readout) {
                Text(tracking).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if readout.isLoading { ProgressView().controlSize(.small) }
            ForEach(Self.toolbarControls(readout), id: \.self) { control in
                Button(control.label) { perform(control) }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The graph, in a lazy list: each row is handed its predecessor and draws two half-edges, so
    /// a viewport is drawable without the assignment around it (Design §4).
    @ViewBuilder
    private func rows(_ readout: SourceControlReadout) -> some View {
        let width = GraphColumn.width(for: readout, metrics: metrics)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(readout.rows.enumerated()), id: \.offset) { index, row in
                    let control = Self.control(for: row)
                    Button {
                        perform(control)
                    } label: {
                        HStack(spacing: 8) {
                            GraphColumn(row: row,
                                        predecessor: index == 0 ? nil : readout.rows[index - 1],
                                        isLastRow: index == readout.rows.count - 1,
                                        metrics: metrics, width: width)
                            RowContent(row: row)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(row.isSelected ? Color.accentColor.opacity(0.18) : .clear)
                    .accessibilityLabel(control.label)
                }
            }
        }
    }

    private func perform(_ control: Control, from destination: LinkDestination = .currentPanel) {
        Task { await control.perform(on: session, from: destination) }
    }

    // MARK: - what the header says

    static func branchLabel(_ readout: SourceControlReadout) -> String {
        if let branch = readout.branch { return branch }
        // Detached `HEAD` is not an error and not an empty repository, and the header says which
        // it is rather than leaving the line blank.
        return readout.isDetachedHead ? "Detached HEAD" : PanelTabID.sourceControl.defaultTitle
    }

    /// The upstream and how far the branch is from it, or nothing when there is no upstream.
    static func trackingLabel(_ readout: SourceControlReadout) -> String? {
        guard let upstream = readout.upstream else { return nil }
        var parts = [upstream]
        if let ahead = readout.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = readout.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }

    // MARK: - the panel's own area (root spec §10)

    typealias NoticePresentation = PanelNoticePresentation

    static func presentation(for readout: SourceControlReadout) -> NoticePresentation {
        presentation(for: readout.notice)
    }

    static func presentation(for notice: SourceControlReadout.Notice?) -> NoticePresentation {
        guard let notice else { return .none }
        switch notice.placement {
        case .emptyState: return .emptyState(message: notice.message, hint: notice.hint)
        case .row: return .banner(message: notice.message, hint: notice.hint)
        }
    }

    // MARK: - the detail pane, as values (Design §6)

    /// One changed-file row, with everything drawn beside its path.
    struct FileRowPresentation: Hashable {
        let path: String
        /// The one-letter glyph git's own vocabulary uses, so a list of rows scans.
        let statusGlyph: String
        let statusLabel: String
        /// What the entry is, when it is not an ordinary file. Nil for one that is — a row that
        /// said "File" beside every path would say nothing.
        let kindLabel: String?
        let additions: String
        let deletions: String
        let isBinary: Bool
        /// Whether clicking this row emits a `.diff` link at all (Design §6's two exclusions).
        let opensADiff: Bool
        /// Why it does not, in the panel's own words. Nil exactly when `opensADiff` is true.
        let exclusionReason: String?
    }

    struct ParentPresentation: Hashable {
        let hash: String
        let abbreviated: String
    }

    /// The whole pane for a selection: a commit's identity and its files, or the working tree's
    /// files alone.
    struct DetailPresentation: Hashable {
        let isWorkingTree: Bool
        let hash: String?
        let abbreviatedHash: String?
        let authorName: String?
        let authorDate: Date?
        let subject: String?
        let badges: [RefBadge]
        let parents: [ParentPresentation]
        let files: [FileRowPresentation]
    }

    static func detailPresentation(for detail: SourceControlReadout.Detail) -> DetailPresentation {
        let files = detail.files.map(presentation(for:))
        switch detail {
        case .workingTree:
            return DetailPresentation(isWorkingTree: true, hash: nil, abbreviatedHash: nil,
                                      authorName: nil, authorDate: nil, subject: nil, badges: [],
                                      parents: [], files: files)
        case .commit(let commit):
            return DetailPresentation(
                isWorkingTree: false, hash: commit.hash, abbreviatedHash: commit.abbreviatedHash,
                authorName: commit.authorName, authorDate: commit.authorDate,
                subject: commit.subject, badges: commit.badges,
                parents: commit.parents.map {
                    ParentPresentation(hash: $0, abbreviated: String($0.prefix(8)))
                },
                files: files)
        }
    }

    static func presentation(for file: SourceControlReadout.FileRow) -> FileRowPresentation {
        FileRowPresentation(path: file.path,
                            statusGlyph: glyph(for: file.status),
                            statusLabel: label(for: file.status),
                            kindLabel: label(for: file.kind),
                            additions: count(file.additions, sign: "+"),
                            deletions: count(file.deletions, sign: "−"),
                            isBinary: file.isBinary,
                            opensADiff: file.opensADiff,
                            exclusionReason: file.exclusionReason)
    }

    static func glyph(for status: FileChange.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        }
    }

    /// The status in words. A rename and a copy name the side they came from, because that side is
    /// the one the `.diff` link does **not** carry — `FileChange.path` is the new path, and C7.5's
    /// resolver reads the old one for itself.
    static func label(for status: FileChange.Status) -> String {
        switch status {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed(let from, let score): "Renamed from \(from) (\(score)%)"
        case .copied(let from, let score): "Copied from \(from) (\(score)%)"
        case .typeChanged: "Type changed"
        }
    }

    static func label(for kind: FileChange.Kind) -> String? {
        switch kind {
        case .file: nil
        case .symlink: "Symbolic link"
        case .gitlink: "Submodule"
        }
    }

    /// A line count, or an em dash for the file git counted none in. Never `0`: a binary file's
    /// counts are absent, and drawing them as zero says git measured a change of nothing.
    static func count(_ value: Int?, sign: String) -> String {
        guard let value else { return "—" }
        return "\(sign)\(value)"
    }

    static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// What a row draws for its date. Relative, because a history is read as "when, relative to
    /// now" far more often than as a timestamp; the detail pane carries the absolute one.
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        dateFormatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - the controls, and the one door to the session (G4)

    /// One interactive control a Source Control surface offers.
    ///
    /// Every control in this file is built by one of the four functions below, and `perform` is
    /// the only place this file calls the session. That is what makes G4's view-layer clause an
    /// assertion about a surface rather than a review of a body: a control carries a
    /// `SourceControlReadout.Action`, the inventory is `CaseIterable`, and an action that is not
    /// in it cannot be offered.
    struct Control: Hashable {
        enum Intent: Hashable {
            case refresh
            case selectCommit(String)
            case selectWorkingTree
            case selectParentCommit(String)
            case openFileDiff(path: String)
        }

        let action: SourceControlReadout.Action
        let label: String
        let intent: Intent

        @MainActor
        func perform(on session: SourceControlModel,
                     from destination: LinkDestination = .currentPanel) async {
            switch intent {
            case .refresh:
                await session.refresh()
            case .selectWorkingTree:
                await session.selectWorkingTree()
            case .selectCommit(let hash), .selectParentCommit(let hash):
                await session.select(commit: hash)
            case .openFileDiff(let path):
                // The session owns the exclusion and the link; this hands it the change the row
                // was built from and nothing else (Design §6).
                guard let change = session.changes.first(where: { $0.path == path }) else { return }
                await session.openDiff(for: change, from: destination)
            }
        }
    }

    static func toolbarControls(_ readout: SourceControlReadout) -> [Control] {
        [Control(action: .refresh, label: "Refresh", intent: .refresh)]
    }

    static func control(for row: SourceControlReadout.Row) -> Control {
        if row.isWorkingTree {
            return Control(action: .selectWorkingTree, label: "Uncommitted changes",
                           intent: .selectWorkingTree)
        }
        let hash = row.commit?.hash ?? ""
        return Control(action: .selectCommit, label: row.commit?.subject ?? hash,
                       intent: .selectCommit(hash))
    }

    static func control(forParent hash: String) -> Control {
        Control(action: .selectParentCommit, label: String(hash.prefix(8)),
                intent: .selectParentCommit(hash))
    }

    /// The control a changed-file row offers, or **none** for the two kinds that are not diffable:
    /// the row states its reason instead of offering a link that resolves to nothing (Design §6).
    static func control(for file: FileRowPresentation) -> Control? {
        guard file.opensADiff else { return nil }
        return Control(action: .openFileDiff, label: file.path,
                       intent: .openFileDiff(path: file.path))
    }

    /// Every control this view offers for `readout`, over every surface it draws. The body builds
    /// its buttons from the same four functions, so this is the surface and not a description of
    /// one.
    static func controls(for readout: SourceControlReadout) -> [Control] {
        var controls = toolbarControls(readout)
        controls += readout.rows.map(control(for:))
        if let detail = readout.detail {
            let pane = detailPresentation(for: detail)
            controls += pane.parents.map { control(forParent: $0.hash) }
            controls += pane.files.compactMap(control(for:))
        }
        return controls
    }
}

// MARK: - the rows

/// What a graph row draws beside its lane: the badges, the abbreviated hash, the subject, the
/// author and the date. The working tree's row has none of them and says so.
private struct RowContent: View {

    let row: SourceControlReadout.Row

    var body: some View {
        HStack(spacing: 6) {
            if row.isWorkingTree {
                Text("Uncommitted changes").font(.callout).italic()
            } else {
                ForEach(row.badges, id: \.self) { badge in
                    RefBadgeLabel(badge: badge)
                }
                Text(row.commit?.subject ?? "").font(.callout).lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let hash = row.abbreviatedHash {
                    Text(hash).font(.caption).monospaced().foregroundStyle(.secondary)
                }
                if let commit = row.commit {
                    Text(commit.authorName).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(SourceControlPanelView.relativeDate(commit.authorTimestamp))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
    }
}

private struct RefBadgeLabel: View {

    let badge: RefBadge

    var body: some View {
        Text(badge.label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: .rect(cornerRadius: 3))
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var tint: Color {
        switch badge.kind {
        case .head: .accentColor
        case .branch: .green
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }
}

// MARK: - the detail pane (Design §6)

private struct DetailPane: View {

    let session: SourceControlModel
    let readout: SourceControlReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = readout.detail {
                let pane = SourceControlPanelView.detailPresentation(for: detail)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        identity(pane)
                        if !pane.parents.isEmpty { parents(pane) }
                        Divider()
                        files(pane)
                    }
                    .padding(10)
                }
                if readout.isLoadingDetail {
                    ProgressView().controlSize(.small).padding(6)
                }
            } else {
                PanelEmptyState(message: "Choose a row to see what it changed.", hint: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func identity(_ pane: SourceControlPanelView.DetailPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if pane.isWorkingTree {
                Text("Uncommitted changes").font(.headline)
                Text("What this working tree has that HEAD does not.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let subject = pane.subject {
                    Text(subject).font(.headline).textSelection(.enabled)
                }
                if let hash = pane.hash {
                    Text(hash).font(.caption).monospaced().textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let author = pane.authorName {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                    if let date = pane.authorDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !pane.badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pane.badges, id: \.self) { RefBadgeLabel(badge: $0) }
                    }
                }
            }
        }
    }

    /// The parent hashes as selectable rows — a navigation between two rows of this panel, and
    /// nothing that touches the repository (§9.2).
    @ViewBuilder
    private func parents(_ pane: SourceControlPanelView.DetailPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.parents.count == 1 ? "Parent" : "Parents")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(pane.parents, id: \.self) { parent in
                let control = SourceControlPanelView.control(forParent: parent.hash)
                Button {
                    Task { await control.perform(on: session) }
                } label: {
                    Text(parent.abbreviated).font(.caption).monospaced()
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func files(_ pane: SourceControlPanelView.DetailPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.files.count == 1 ? "1 file" : "\(pane.files.count) files")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(pane.files, id: \.self) { file in
                if let control = SourceControlPanelView.control(for: file) {
                    Button {
                        Task { await control.perform(on: session) }
                    } label: {
                        FileRow(file: file)
                    }
                    .buttonStyle(.plain)
                    // §9.4: Cmd-click asks for a window of its own, which the Files target pops
                    // out. Nothing else about the click changes.
                    .modifier(CommandClick {
                        Task { await control.perform(on: session, from: .newWindow) }
                    })
                } else {
                    FileRow(file: file)
                }
            }
        }
    }
}

/// One changed file. A row with no diff to offer draws its reason where the others draw a link.
private struct FileRow: View {

    let file: SourceControlPanelView.FileRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(file.statusGlyph)
                    .font(.caption).monospaced().frame(width: 12)
                    .foregroundStyle(.secondary)
                    .help(file.statusLabel)
                Text(file.path).font(.callout).lineLimit(1).truncationMode(.middle)
                if let kind = file.kindLabel {
                    Text(kind).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(file.additions).font(.caption).foregroundStyle(.green)
                Text(file.deletions).font(.caption).foregroundStyle(.red)
            }
            if let reason = file.exclusionReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
    }
}

/// Cmd-click, as a modifier so the row keeps its ordinary button behaviour.
private struct CommandClick: ViewModifier {

    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().modifiers(.command).onEnded(action))
    }
}

// MARK: - the panel's own area

/// How a notice is drawn: replacing a tab's content, or above it.
///
/// The readout decides *which* — a directory in no repository has nothing to put behind a row, a
/// read that failed after the graph was drawn does — and this is the views' side of that decision,
/// as a value a test can read. Both tabs share it because both draw the same two shapes.
enum PanelNoticePresentation: Equatable {
    case none
    case banner(message: String, hint: String?)
    case emptyState(message: String, hint: String?)
}

/// A notice that replaces the panel's content, with the one thing the user can do when there is
/// one. Root spec §10: none of this crosses into the conversation.
struct PanelEmptyState: View {

    let message: String
    let hint: String?

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A notice that sits above content there still is.
struct PanelBanner: View {

    let message: String
    let hint: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.callout).foregroundStyle(.secondary)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}
