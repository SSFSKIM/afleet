import Foundation

/// What the URL bar does with what the user typed — the ledger's Q9 table, and nothing else.
///
/// It is a free function over a string so it can be tested by table, because this is where a
/// browser panel is usually wrong. Two rules are worth reading before changing anything here.
///
/// **There is no web-search fallback, and there must never be one.** A typed string that is not a
/// URL going to a search engine is a keystroke leaving the machine. This panel has no search
/// provider, is not getting one, and answers a phrase with an inline "not a URL" state instead.
///
/// **`localhost:8123` is not a scheme.** `URL(string:)` parses it as one — scheme `localhost`,
/// path `8123` — and a URL bar that trusted `URL(string:)` would fail silently on the single most
/// common thing anyone types into a developer tool's browser. The loopback and `host:port` rows
/// below are checked *before* any scheme is believed, which is the whole reason they are rows.
public enum URLInput {

    /// The three outcomes. `empty` is not an error: an empty URL bar submitted does nothing.
    public enum Normalized: Sendable, Equatable {
        case empty
        case url(URL)
        case notAURL
    }

    /// Schemes typed in full and taken as typed (Q9 row 2). Everything a page can *link* to is
    /// `NavigationPolicy`'s business; this is only what the bar itself resolves.
    private static let literalSchemes: Set<String> = ["http", "https", "about"]

    public static func normalize(_ raw: String) -> Normalized {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Row 1.
        guard !input.isEmpty else { return .empty }

        // Row 2 — but only for the three schemes the table names, so that `localhost:8123` never
        // reaches this branch as scheme `localhost`.
        if let scheme = leadingScheme(of: input), literalSchemes.contains(scheme) {
            return resolve(input)
        }

        // Rows 3 and 4: anything loopback, and anything `host:<digits>`, is a local server and
        // takes plain HTTP. `https://localhost:8123` would fail a TLS handshake that was never
        // offered, which is the failure this row exists to prevent.
        if isLoopback(input) || isHostAndNumericPort(input) {
            return resolve("http://" + input)
        }

        // Row 5.
        if input.contains("."), input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return resolve("https://" + input)
        }

        // Row 6.
        return .notAURL
    }

    // MARK: The rows

    /// The scheme of `input` if it begins with one, lowercased. RFC 3986's production, so that
    /// `x-apple-something:` is recognised as a scheme even though this type will not resolve it.
    private static func leadingScheme(of input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let candidate = input[input.startIndex..<colon]
        guard let first = candidate.first, first.isLetter else { return nil }
        let allowed = candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
        return allowed ? candidate.lowercased() : nil
    }

    /// `localhost`, `*.localhost`, `127.0.0.1`, `[::1]`, each optionally with `:port` and a path.
    ///
    /// The bare forms are included, not only the ones the table spells with a port: `127.0.0.1`
    /// alone contains a dot and would otherwise fall to row 5 and be handed `https://`.
    private static func isLoopback(_ input: String) -> Bool {
        let authority = String(input.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty else { return false }

        let host: String
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return false }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            guard tail.isEmpty || (tail.hasPrefix(":") && tail.dropFirst().allSatisfy(\.isNumber) && tail.count > 1)
            else { return false }
        } else if let colon = authority.firstIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
        } else {
            host = authority
        }

        let lowered = host.lowercased()
        return lowered == "localhost"
            || lowered.hasSuffix(".localhost")
            || lowered == "127.0.0.1"
            || lowered == "::1"
    }

    /// A bare `host:<all digits>`, optionally with a path — row 4. The digit requirement is what
    /// keeps `mailto:someone` and `notahost:eight` out of it.
    private static func isHostAndNumericPort(_ input: String) -> Bool {
        let authority = String(input.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard let colon = authority.firstIndex(of: ":") else { return false }
        let host = authority[authority.startIndex..<colon]
        let port = authority[authority.index(after: colon)...]
        guard !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// A string this function has decided is a URL, if `URL` agrees. It does not always: a string
    /// can pass a row and still not parse, and the honest answer then is the same as row 6's.
    private static func resolve(_ string: String) -> Normalized {
        guard let url = URL(string: string), url.scheme != nil else { return .notAURL }
        return .url(url)
    }
}
