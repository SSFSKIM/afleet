import Darwin
import Foundation

public enum PTYOperation: Hashable, Sendable {
    case openPTY
    case configureDescriptor
    case initializeFileActions
    case changeWorkingDirectory
    case openSlave
    case duplicateSlave
    case closeInheritedDescriptor
    case initializeSpawnAttributes
    case setSignalDefaults
    case setSpawnFlags
    case allocateArguments
    case spawn
    case readForegroundProcessGroup
    case write
}

public enum PTYError: Error, Equatable, Sendable {
    case executableUnavailable
    case workingDirectoryUnavailable
    case systemCall(operation: PTYOperation, code: Int32)
    case closed
}

struct DarwinPTYSpawnResult: Sendable {
    let masterDescriptor: Int32
    let processIdentifier: pid_t
}

enum DarwinPTY {
    static func spawn(_ request: PTYSpawnRequest) throws -> DarwinPTYSpawnResult {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: request.executable.path) else {
            throw PTYError.executableUnavailable
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: request.cwd.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PTYError.workingDirectoryUnavailable
        }

        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var slaveName = [CChar](repeating: 0, count: Int(PATH_MAX))
        var windowSize = winsize(
            ws_row: UInt16(truncatingIfNeeded: request.size.rows),
            ws_col: UInt16(truncatingIfNeeded: request.size.columns),
            ws_xpixel: UInt16(truncatingIfNeeded: request.size.pixelWidth),
            ws_ypixel: UInt16(truncatingIfNeeded: request.size.pixelHeight)
        )
        let openResult = slaveName.withUnsafeMutableBufferPointer { name in
            openpty(
                &masterDescriptor,
                &slaveDescriptor,
                name.baseAddress,
                nil,
                &windowSize
            )
        }
        guard openResult == 0 else {
            throw PTYError.systemCall(operation: .openPTY, code: errno)
        }

        var parentOwnsMaster = true
        var parentOwnsSlave = true
        defer {
            if parentOwnsSlave {
                _ = Darwin.close(slaveDescriptor)
            }
            if parentOwnsMaster {
                _ = Darwin.close(masterDescriptor)
            }
        }

        // Both parent ends are closed on exec before anything else can spawn: without this a
        // pane spawned later inherits an earlier pane's master and holds that pane's terminal
        // open after its own child has gone. `POSIX_SPAWN_CLOEXEC_DEFAULT` below covers this
        // layer's own spawns; the descriptor flag covers every other spawner in the process.
        // O_NONBLOCK is the parent's master only — the child opens the slave by name and its
        // descriptors are unaffected — and it is what keeps a large write off the actor.
        let masterStatusFlags = fcntl(masterDescriptor, F_GETFL)
        guard masterStatusFlags != -1,
              fcntl(masterDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(slaveDescriptor, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(masterDescriptor, F_SETFL, masterStatusFlags | O_NONBLOCK) != -1 else {
            throw PTYError.systemCall(operation: .configureDescriptor, code: errno)
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else {
            throw PTYError.systemCall(operation: .initializeFileActions, code: result)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        result = request.cwd.path.withCString {
            posix_spawn_file_actions_addchdir(&fileActions, $0)
        }
        try requireSuccess(result, operation: .changeWorkingDirectory)

        result = slaveName.withUnsafeBufferPointer {
            posix_spawn_file_actions_addopen(&fileActions, 0, $0.baseAddress, O_RDWR, 0)
        }
        try requireSuccess(result, operation: .openSlave)
        try requireSuccess(
            posix_spawn_file_actions_adddup2(&fileActions, 0, 1),
            operation: .duplicateSlave
        )
        try requireSuccess(
            posix_spawn_file_actions_adddup2(&fileActions, 0, 2),
            operation: .duplicateSlave
        )
        try requireSuccess(
            posix_spawn_file_actions_addclose(&fileActions, slaveDescriptor),
            operation: .closeInheritedDescriptor
        )
        try requireSuccess(
            posix_spawn_file_actions_addclose(&fileActions, masterDescriptor),
            operation: .closeInheritedDescriptor
        )

        var attributes: posix_spawnattr_t? = nil
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw PTYError.systemCall(operation: .initializeSpawnAttributes, code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // A disposition the parent left as SIG_IGN survives exec, and a shell keeps an
        // inherited SIG_IGN ignored. SIGPIPE is the one that matters — Foundation and XCTest
        // both ignore it — and a child that cannot die of a broken pipe hangs instead of
        // ending. The child starts from the default disposition for every catchable signal.
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        sigdelset(&defaultedSignals, SIGKILL)
        sigdelset(&defaultedSignals, SIGSTOP)
        result = posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
        try requireSuccess(result, operation: .setSignalDefaults)

        // CLOEXEC_DEFAULT closes every descriptor the file actions do not name, so the child
        // receives its terminal and nothing else. The explicit closes below stay: they are what
        // names the inherited master and slave, and under CLOEXEC_DEFAULT they are also what
        // keeps the intent readable when the flag is read alone.
        result = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        try requireSuccess(result, operation: .setSpawnFlags)

        let argumentStrings = [request.executable.path] + request.arguments
        let environmentStrings = request.environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        result = try withCStringVector(argumentStrings) { arguments in
            try withCStringVector(environmentStrings) { environment in
                request.executable.path.withCString { executable in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }

        // The descriptor must remain open until posix_spawn returns. Closing it before the
        // child opens the slave by name resets the pty's initial window size on macOS.
        _ = Darwin.close(slaveDescriptor)
        parentOwnsSlave = false

        guard result == 0 else {
            throw PTYError.systemCall(operation: .spawn, code: result)
        }
        parentOwnsMaster = false
        return DarwinPTYSpawnResult(
            masterDescriptor: masterDescriptor,
            processIdentifier: processIdentifier
        )
    }

    private static func requireSuccess(_ result: Int32, operation: PTYOperation) throws {
        guard result == 0 else {
            throw PTYError.systemCall(operation: operation, code: result)
        }
    }

    private static func withCStringVector<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(strings.count)
        defer { allocated.forEach { free($0) } }

        for string in strings {
            guard let pointer = string.withCString({ strdup($0) }) else {
                throw PTYError.systemCall(operation: .allocateArguments, code: ENOMEM)
            }
            allocated.append(pointer)
        }
        var vector = allocated.map(Optional.some)
        vector.append(nil)
        return try vector.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
