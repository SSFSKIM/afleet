import Foundation

/// Untrusted text, stripped before it is laid out (child spec §5, parity §41.7).
///
/// **This is security-relevant and it is nobody else's in this cut.** The engine sanitises at paint
/// time and the host receives the raw text, so a bidi override or a zero-width mark in tool output
/// or in model text renders in afleet unless this runs first. Parity §41.7 names the strip set as
/// two passes — the `Cc`/`Cf`/`Cs`/`Co`/`Cn` categories, U+2028/29, the default-ignorables and
/// U+2800, then the bidi overrides, the zero-width marks, U+FEFF and the private-use planes — and
/// iterates them up to ten times. One scalar-wise pass over the union is the same fixed point:
/// removing a scalar cannot create one, so a second pass has nothing left to find.
///
/// **Newline and tab survive.** They are `Cc`, and markdown is made of them: a sanitiser that took
/// them would flatten every fenced block and every list in the transcript.
enum TextSanitiser {

    /// The strip set, applied in one pass.
    ///
    /// Scalar-wise and allocation-light: the overwhelmingly common case is text with nothing to
    /// strip, and this runs on every block of every message before it is laid out.
    static func sanitise(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isStripped) else { return text }
        var kept = String.UnicodeScalarView()
        kept.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where !isStripped(scalar) { kept.append(scalar) }
        return String(kept)
    }

    /// Whether one scalar is in the strip set.
    ///
    /// The two `Cc` scalars markdown is made of are exempt before anything else is asked, because
    /// they are the structure and not the payload. Everything else parity §41.7 names is here: the
    /// five `C` categories, the two separators, the default-ignorables — which is where the bidi
    /// overrides, the bidi isolates, the zero-width marks and U+FEFF already are — and the braille
    /// blank, which is not ignorable to Unicode and is invisible on screen.
    static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: break
        }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        // U+2028 and U+2029 are `Zl` and `Zp`, so they are not caught above; a GUI treating either
        // as a line break would let tool output forge a paragraph in the transcript.
        return scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0x2800
    }
}
