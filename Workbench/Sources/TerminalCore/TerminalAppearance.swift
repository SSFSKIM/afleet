/// How a ``TerminalAppearance/themeName`` resolved against the renderer's theme catalog.
///
/// A name the catalog does not know renders exactly like no name at all, so the rendered terminal
/// cannot tell a typo from "follow the system". This is where the two are told apart.
public enum TerminalThemeResolution: Hashable, Sendable {
    /// No name was asked for: the renderer follows the current system appearance.
    case systemAppearance
    /// The named theme was found and applied.
    case named(String)
    /// The name is not in the catalog. The renderer shows the system-appearance default instead.
    case unknownName(String)
}

public struct TerminalAppearance: Hashable, Sendable {
    /// A renderer theme name. `nil` follows the current system appearance. A name the renderer's
    /// catalog does not know falls back to that same appearance, and only
    /// ``TerminalThemeResolution`` distinguishes the two.
    public var themeName: String?
    public var fontName: String?
    public var fontSize: Float?

    public init(
        themeName: String? = nil,
        fontName: String? = nil,
        fontSize: Float? = nil
    ) {
        self.themeName = themeName
        self.fontName = fontName
        self.fontSize = fontSize
    }
}
