import Foundation
import XCTest

/// The suite's one waiting primitive, and the bound every wait in it shares.
///
/// A test here observes work that runs on other tasks — an ingestion folding a tap, a tailer polling a file — and the
/// only sound way to wait for that work is to wait for its *arrival*. Waiting a fixed span instead measures the host:
/// the same 500 ms window that is ten times enough on an idle machine ended with 5 of 15 effects collected on one
/// carrying a 15-minute load average of 89, and the count assertion after it then reported a dropped frame that had
/// not been dropped (tracker 194; the same class as 161's tailer wait). Nothing here is a budget for the code under
/// test: `hangGuard` exists to turn a hang into a failure, and what a failure reports is a count.
enum TestTiming {

    /// The bound on a delivery wait. No passing path waits on this clock, so it is set far above anything scheduling
    /// delay can reach: the work these waits cover is a second of it, and the loaded runs on record stretched a wait
    /// by about fiftyfold.
    static let hangGuard: Duration = .seconds(120)

    /// Waits until `delivered` reaches `want`. The wait ends on delivery; the guard only fails, and its message
    /// carries counts and nothing else — no path, no host, per spec §6.3 and §11.
    static func awaitDelivery(_ what: String, of want: Int,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ delivered: @Sendable () -> Int) async {
        let deadline = ContinuousClock.now.advanced(by: hangGuard)
        while true {
            let have = delivered()
            if have >= want { return }
            if ContinuousClock.now >= deadline {
                return XCTFail("\(what): \(have) of \(want) delivered inside the hang guard", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
