import Foundation

/// The one extension-to-language map both `open` and `showDiff` use (spec Design §2).
///
/// `showDiff` builds its two models without a URI, so Monaco cannot infer a language for a diff
/// from a file name and the `language` argument is the only source; `open` builds its model *at*
/// the URI, where Monaco could infer. Using one map for both is what keeps a file and its diff
/// from being highlighted two different ways.
///
/// The table is deliberately smaller than the bundle's registrations — it carries the extensions
/// this repository and a working tree commonly hold — and anything unmapped is `plaintext`, which
/// is what Monaco would have inferred anyway. `FileKindTests` checks every id and every extension
/// here against the registrations parsed out of the committed bundle, so a typo, an invented id or
/// a Monaco bump that renames a language fails a test rather than showing a file as plain text in
/// front of a user.
///
/// Extensions the bundle registers ambiguously are left out on purpose rather than guessed at:
/// `.pp` (pascal *and* ruby), `.s` (mips), `.ml`/`.mli` (fsharp, not OCaml) and `.sc` (scala).
public enum MonacoLanguage {

    /// Monaco's own default, and the answer for anything unmapped. It is registered by the
    /// bundle through minified identifiers rather than string literals, so the bundle test
    /// exempts it by name rather than expecting to parse it.
    public static let fallback = "plaintext"

    /// Lowercased extension, without the dot, to Monaco language id.
    public static let extensionMap: [String: String] = [
        // this repository
        "swift": "swift",
        "md": "markdown", "markdown": "markdown", "mdx": "mdx",
        "json": "json", "yaml": "yaml", "yml": "yaml",
        "sh": "shell", "bash": "shell",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "es6": "javascript",
        "ts": "typescript", "tsx": "typescript", "cts": "typescript", "mts": "typescript",
        "html": "html", "htm": "html", "xhtml": "html",
        "css": "css", "scss": "scss", "less": "less",
        "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "svg": "xml", "svgz": "xml",
        "csproj": "xml", "props": "xml", "targets": "xml", "config": "xml", "xaml": "xml",
        "ini": "ini", "properties": "ini",
        // common working-tree languages
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "m": "objective-c",
        "cs": "csharp", "csx": "csharp", "cake": "csharp",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "go": "go", "rs": "rust", "rlib": "rust",
        "py": "python", "pyw": "python",
        "rb": "ruby", "gemspec": "ruby",
        "java": "java", "jav": "java",
        "kt": "kotlin", "kts": "kotlin",
        "scala": "scala", "sbt": "scala",
        "php": "php", "phtml": "php",
        "pl": "perl", "pm": "perl",
        "lua": "lua", "r": "r", "jl": "julia", "dart": "dart",
        "ex": "elixir", "exs": "elixir",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
        "coffee": "coffeescript",
        "sql": "sql",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "bat": "bat", "cmd": "bat",
        "dockerfile": "dockerfile",
        "graphql": "graphql", "gql": "graphql",
        "proto": "proto",
        "tf": "hcl", "tfvars": "hcl", "hcl": "hcl",
        "sol": "sol", "tcl": "tcl", "wgsl": "wgsl",
        "v": "verilog", "vh": "verilog", "sv": "systemverilog", "svh": "systemverilog",
        "vb": "vb", "rst": "restructuredtext",
        "pug": "pug", "jade": "pug", "twig": "twig", "liquid": "liquid",
        "hbs": "handlebars", "handlebars": "handlebars", "cshtml": "razor",
        "qs": "qsharp", "bicep": "bicep",
    ]

    /// Whole file names, for the files that carry their type in the name rather than in an
    /// extension. `URL.pathExtension` is empty for every one of these.
    ///
    /// The leading-dot names are the same strings the bundle registers as "extensions" — Monaco
    /// matches them as filename suffixes — so the bundle test checks them against that table too.
    public static let filenameMap: [String: String] = [
        "dockerfile": "dockerfile",
        ".gitconfig": "ini",
        ".babelrc": "json", ".bowerrc": "json", ".eslintrc": "json",
        ".jshintrc": "json", ".jscsrc": "json",
    ]

    /// The language id for a file, matched by name first and by lowercased extension second.
    public static func id(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if let byName = filenameMap[name] { return byName }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return fallback }
        return extensionMap[ext] ?? fallback
    }
}
