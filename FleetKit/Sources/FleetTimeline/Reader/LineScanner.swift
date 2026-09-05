import Foundation

/// Splits transcript bytes into complete lines. The engine seals a torn tail by writing a leading `\n` before the next
/// record (parity §35.1), so an empty line is skipped, and a final run of bytes without a terminator is *held back*: it is
/// returned as `partial` and never decoded, because the next append will complete it.
public enum LineScanner {
    public struct Scan: Sendable {
        public var lines: [(offset: Int, bytes: Data)]; public var consumed: Int; public var partial: Data?
        public init(lines: [(offset: Int, bytes: Data)], consumed: Int, partial: Data?) { self.lines = lines; self.consumed = consumed; self.partial = partial }
    }
    public static func scan(_ data: Data, base: Int = 0) -> Scan {
        var lines: [(Int, Data)] = []; var start = data.startIndex
        while let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = data[start..<nl]
            while let first = line.first, first <= 32 { line = line.dropFirst() }      // the engine's own whitespace skip (`Qr`, line 250499)
            if !line.isEmpty { lines.append((base + (start - data.startIndex), Data(line))) }
            start = data.index(after: nl)
        }
        let rest = data[start...]
        return Scan(lines: lines.map { (offset: $0.0, bytes: $0.1) }, consumed: start - data.startIndex, partial: rest.isEmpty ? nil : Data(rest))
    }
    /// The complete lines alone, for a caller that has no use for the held-back tail.
    public static func lines(in data: Data, base: Int = 0) -> [(offset: Int, bytes: Data)] { scan(data, base: base).lines }
}
