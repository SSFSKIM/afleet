import Foundation

/// Serialises writes to the child's stdin on a dedicated thread (a full pipe blocks that thread, never a cooperative one);
/// each caller suspends until its bytes are in the pipe, which is the bounded back-pressure the spec asks for. EPIPE surfaces as an error.
public actor StdinWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "afleet.stdin-writer")
    private var closed = false
    public init(handle: FileHandle) { self.handle = handle }
    public func write(_ data: Data) async throws {
        guard !closed else { throw StdinClosed() }
        let line: Data = data.last == 0x0A ? data : data + [0x0A]
        let handle = self.handle
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try handle.write(contentsOf: line); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }
    public func close() {
        guard !closed else { return }
        closed = true
        let handle = self.handle
        queue.async { try? handle.close() }
    }
    public struct StdinClosed: Error {}
}
