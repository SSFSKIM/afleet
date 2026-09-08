import GhosttyTerminal
import GhosttyTheme

struct GhosttyAppearance {
    let configuration: TerminalConfiguration
    let theme: TerminalTheme

    init(_ appearance: TerminalAppearance) {
        var configuration = TerminalConfiguration()
        if let fontName = appearance.fontName {
            configuration = configuration.fontFamily(fontName)
        }
        if let fontSize = appearance.fontSize {
            configuration = configuration.fontSize(fontSize)
        }
        self.configuration = configuration

        if let themeName = appearance.themeName,
           let definition = GhosttyThemeCatalog.theme(named: themeName) {
            theme = definition.toTerminalTheme()
        } else {
            theme = .default
        }
    }
}
