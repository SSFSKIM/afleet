// C7.5 spec Design §1, §4 and §10: what the panel draws, as a value.
import Foundation

/// Everything `FilesPanelView` draws about the content column, reduced to a value.
///
/// It exists for the reason C5's `PlaceholderReadout` exists: a rendered `Text` is not an
/// assertion. The view reads these fields and formats nothing else, so a test that asserts on a
/// readout is asserting on what the window shows — which viewer is on screen, whose file it is,
/// whether the banner is up, and what the panel-local area is saying.
///
/// **The name and never the path.** §6.3 and §11: a failed assertion prints both values, and the
/// panel's own header shows the file's name, so the name is what this carries. The path stays on
/// the session, where *Reveal in Finder* and *Copy path* reach it without an assertion printing it.
@MainActor
public struct FilesPanelReadout: Equatable {

    /// Which surface the content column is showing. `.nothing` is the empty state and the state a
    /// panel-local error leaves behind; `.unsupported` is Design §4's last case — a file that is
    /// none of the viewers, or above the cap, drawn as its size with *Reveal in Finder* rather
    /// than loaded.
    public enum Viewer: String, Equatable, Sendable, CaseIterable {
        case nothing, diff, editor, markdown, image, pdf, media, quickLook, unsupported
    }

    public let selectedName: String?
    public let viewer: Viewer
    public let isDirty: Bool
    /// The file was there when it was opened and is not there now. Drawn beside the name.
    public let isMissing: Bool
    /// Whether the *Reload* / *Keep mine* banner is up.
    public let showsConflictBanner: Bool
    /// Whether the markdown toggle is offered, and which way it is set.
    public let offersMarkdownToggle: Bool
    public let rendersMarkdown: Bool
    /// What the selected file's bytes were the last time the session read them, as a digest.
    ///
    /// The native previews compare it alongside the URL, because a URL alone is not an identity
    /// for a file the agent is rewriting: the path does not move when the contents do, and a view
    /// whose stored properties are otherwise unchanged would keep a render of bytes that are gone.
    /// Empty for a file the panel never read — one above the cap — which means "the URL is the
    /// whole identity". A digest is not a path and not a buffer (§6.3, §11).
    public let revision: String
    public let isFilterActive: Bool
    public let openFileCount: Int
    /// What the panel-local area is showing (root spec §10). None of it reaches the channel.
    public let issue: FilesPanelSession.Issue?

    public init(session: FilesPanelSession) {
        let file = session.selected
        selectedName = file?.name
        isDirty = file?.isDirty ?? false
        isMissing = file?.isMissing ?? false
        showsConflictBanner = file?.hasConflict ?? false
        offersMarkdownToggle = file?.kind == .markdown
        rendersMarkdown = file?.rendersMarkdown ?? true
        revision = file?.lastLoaded?.digest ?? ""
        isFilterActive = !session.tree.filter.isEmpty
        openFileCount = session.openFiles.count
        issue = session.issue
        viewer = Self.viewer(showingDiff: session.isShowingDiff, file: file)
    }

    /// The decision, in Design §4's own order: a diff on screen is the surface whatever is
    /// selected, and otherwise the selected file's kind names the viewer. `usesEditor` is the
    /// session's own switch, so markdown moves between the two surfaces on the user's toggle and
    /// nowhere else.
    private static func viewer(showingDiff: Bool, file: FilesPanelSession.OpenFile?) -> Viewer {
        if showingDiff { return .diff }
        guard let file else { return .nothing }
        if file.usesEditor { return .editor }
        switch file.kind {
        case .code: return .editor
        case .markdown: return .markdown
        case .image: return .image
        case .pdf: return .pdf
        case .media: return .media
        case .quickLook: return .quickLook
        // A file whose bytes contradict its name is already `.binary`, and so is one above the
        // cap. Neither is handed to a viewer that would fail inside itself (Design §4).
        case .binary: return .unsupported
        }
    }

    /// The one line the panel-local area draws, or nothing when there is nothing to say.
    ///
    /// Deliberately naming no path, no message from the editor and no output from git: a panel's
    /// errors stay in the panel (root spec §10) and a line naming a file is what §11 forbids.
    public var notice: String? {
        switch issue {
        case .none: return nil
        case .unreadableFile: return "This file could not be opened."
        case .saveFailed: return "The file could not be written. Your changes are still here."
        case .saveRefusedWhileDiffShown: return "Close the diff before saving."
        case .saveRefusedIntoConfigHome:
            return "afleet never writes inside a Claude Code configuration directory."
        case .editorReported: return "The editor reported a problem."
        case .diffUnavailable: return "The repository could not be read."
        case .noTextDiff(let reason):
            switch reason {
            case .pathUnchangedByBase: return "Nothing changed here at this revision."
            case .binaryContent: return "There is no text diff for this file."
            case .submodule: return "This entry is a submodule."
            }
        }
    }
}
