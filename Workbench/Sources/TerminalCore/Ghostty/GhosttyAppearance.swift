import GhosttyTerminal
import GhosttyTheme

struct GhosttyAppearance {
    let configuration: TerminalConfiguration
    let theme: TerminalTheme
    /// What became of the requested theme name. The fallback is deliberately invisible on screen —
    /// a pane with a mistyped theme still renders — so the outcome is reported here rather than
    /// being swallowed by the theme it fell back to.
    let themeResolution: TerminalThemeResolution

    init(_ appearance: TerminalAppearance) {
        var configuration = TerminalConfiguration()
        if let fontName = appearance.fontName {
            configuration = configuration.fontFamily(fontName)
        }
        if let fontSize = appearance.fontSize {
            configuration = configuration.fontSize(fontSize)
        }
        self.configuration = configuration

        switch appearance.themeName {
        case .none:
            theme = .default
            themeResolution = .systemAppearance
        case let .some(themeName):
            if let definition = GhosttyThemeCatalog.theme(named: themeName) {
                theme = definition.toTerminalTheme()
                themeResolution = .named(themeName)
            } else {
                theme = .default
                themeResolution = .unknownName(themeName)
            }
        }
    }
}
