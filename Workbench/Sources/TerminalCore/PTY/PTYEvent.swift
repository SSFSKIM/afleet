import Foundation

public enum PTYEvent: Sendable {
    case output(Data)
    case stopped(signal: Int32)
    case ended(PTYTermination)
}

public enum PTYTermination: Hashable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32)

    /// The lossy status consumed by C4's `PaneExit`: an exit code, or 128 plus a signal.
    public var paneExitCode: Int32 {
        switch self {
        case let .exited(code):
            code
        case let .signalled(signal):
            128 + signal
        }
    }
}
