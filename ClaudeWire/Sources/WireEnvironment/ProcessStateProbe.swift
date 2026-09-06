import Foundation

/// What the kernel says about a pid, at the one moment worth asking: when a child has outlasted its budget.
///
/// `kill(pid, 0)` cannot answer this. It succeeds for a zombie exactly as it does for a live process, and the
/// difference between the two is the whole question — a zombie has exited and nobody reaped it, while a live
/// process has not exited at all, and those point at opposite halves of the system.
public enum ProcessLiveness: String, Sendable {
    /// No such process: it exited and its status was collected by someone.
    case gone
    /// Exited, not yet reaped. Its exit status is still there for the taking.
    case zombie
    /// Running, sleeping or stopped — in any case it has not exited.
    case alive
}

/// A pid, what the kernel says about it, and the executable's short name. Identifiers and states only: `p_comm`
/// is the basename the kernel keeps, never a path and never an argument, so this is safe to log verbatim.
public struct ProcessState: Sendable, CustomStringConvertible {
    public let pid: pid_t
    public let liveness: ProcessLiveness
    /// Empty when the process is gone, since the kernel has nothing left to name.
    public let name: String
    public var description: String { "pid=\(pid) liveness=\(liveness.rawValue) name=\(name)" }
}

/// Asks the kernel directly, through `sysctl`, rather than by spawning `ps`.
///
/// Deliberately: this is called when a child has already failed to settle, which is precisely when Foundation's
/// own child-monitoring is a suspect, and a diagnostic that spawns a process to describe a process would be
/// leaning on the machinery it is trying to describe. `sysctl` needs no child and cannot block.
public func probeProcessState(_ pid: pid_t) -> ProcessState {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = mib.withUnsafeMutableBufferPointer { buffer in
        sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
    }
    // A pid the kernel does not know returns ESRCH; a pid it knows but has already torn down comes back with a
    // zero-length record, which is the same answer.
    guard rc == 0, size > 0 else { return ProcessState(pid: pid, liveness: .gone, name: "") }
    let name = withUnsafePointer(to: info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.kp_proc.p_comm)) {
            String(cString: $0)
        }
    }
    let zombie = info.kp_proc.p_stat == SZOMB
    return ProcessState(pid: pid, liveness: zombie ? .zombie : .alive, name: name)
}
