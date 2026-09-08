import Foundation

/// Progress lines on stderr, written unbuffered so a stalled run says where it stalled.
/// stdout stays reserved for the one JSON report.
enum Trace {
    nonisolated(unsafe) static var start = Date()

    static func log(_ message: String) {
        let elapsed = Date().timeIntervalSince(start) * 1000
        FileHandle.standardError.write(Data(String(format: "[%8.1f ms] %@\n", elapsed, message).utf8))
    }
}
