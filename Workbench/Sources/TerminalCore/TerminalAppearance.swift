public struct TerminalAppearance: Hashable, Sendable {
    /// A renderer theme name. `nil` follows the current system appearance.
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
