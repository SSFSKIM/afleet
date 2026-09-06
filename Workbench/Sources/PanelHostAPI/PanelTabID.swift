import Foundation

/// The closed set of panel tabs, in the canonical order the tab bar shows them and
/// `PanelHost.available(for:)` returns them. Adding a case is a change to contract X7.
public enum PanelTabID: String, CaseIterable, Codable, Hashable, Sendable {
    case thread, agents, files, sourceControl, terminal, browser, github

    public var defaultTitle: String {
        switch self {
        case .thread: "Thread"
        case .agents: "Agents"
        case .files: "Files"
        case .sourceControl: "Source Control"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .github: "GitHub"
        }
    }

    public var defaultSystemImage: String {
        switch self {
        case .thread: "bubble.left.and.bubble.right"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .files: "doc.text"
        case .sourceControl: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .browser: "globe"
        case .github: "chevron.left.forwardslash.chevron.right"
        }
    }
}
