import Darwin
import Foundation
import LatheLocalization

/// Acquire before opening the database. This owner controls the lifetime lease.
public final class EngineLease: @unchecked Sendable {
    /// Borrowed handle; this lease owns unlocking and closing it.
    let descriptor: Int32

    public init(paths: EnginePaths) throws {
        let fd = try SocketSecurity.openLock(paths.engineLockPath)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw SocketTransportError.alreadyRunning }
            throw SocketTransportError.systemCall("engine flock", code)
        }
        do {
            if let original = try SocketSecurity.metadata(paths.socketPath) {
                _ = try SocketSecurity.validateSocket(paths.socketPath)
                guard try !SocketIO.isReady(path: paths.socketPath, deadline: SocketIO.deadline()) else {
                    throw SocketTransportError.alreadyRunning
                }
                guard let current = try SocketSecurity.metadata(paths.socketPath),
                      original.st_dev == current.st_dev, original.st_ino == current.st_ino,
                      current.st_mode & S_IFMT == S_IFSOCK else {
                    throw SocketTransportError.unsafePath(paths.socketPath)
                }
                guard unlink(paths.socketPath) == 0 else {
                    throw SocketTransportError.systemCall("unlink stale socket", errno)
                }
            }
            descriptor = fd
        } catch {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
    }

    deinit {
        // A concurrent spawn can briefly retain this open file description
        // before exec applies CLOEXEC. End ownership now, even if it has copies.
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum EngineBootstrap {
    /// Checks connection readiness only. The RPC client performs the version
    /// handshake before using the engine; an incompatible live engine is not replaced.
    public static func ensureRunning(paths: EnginePaths, executableURL: URL) async throws {
        try await blockingIO {
            let deadline = SocketIO.deadline()
            let bootstrap = try SocketSecurity.openLock(paths.bootstrapLockPath)
            defer { close(bootstrap) }
            while flock(bootstrap, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw SocketTransportError.systemCall("bootstrap flock", errno)
                }
                try pause(until: deadline)
            }
            defer { _ = flock(bootstrap, LOCK_UN) }
            if try isReady(paths: paths, deadline: deadline) { return }

            let lease = try SocketSecurity.openLock(paths.engineLockPath)
            let lockResult = flock(lease, LOCK_EX | LOCK_NB)
            let lockError = errno
            if lockResult == 0 { _ = flock(lease, LOCK_UN) }
            close(lease)
            var child: EngineChild?
            if lockResult == 0 {
                child = try spawn(executableURL: executableURL, paths: paths)
            } else if lockError != EWOULDBLOCK {
                throw SocketTransportError.systemCall("engine flock probe", lockError)
            }
            while try !isReady(paths: paths, deadline: deadline) {
                if let status = child?.status {
                    throw SocketTransportError.launchFailed(L10n.format("protocol.launch.childExited", table: "ProtocolErrors", String(status), startupLog(paths).path))
                }
                do { try pause(until: deadline) }
                catch {
                    throw SocketTransportError.launchFailed(L10n.format("protocol.launch.notReady", table: "ProtocolErrors", startupLog(paths).path))
                }
            }
        }
    }

    private static func pause(until deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SocketTransportError.timeout }
        usleep(10_000)
    }

    private static func isReady(paths: EnginePaths, deadline: UInt64) throws -> Bool {
        // bind creates the inode before chmod publishes its final mode. Never
        // connect during this small startup interval, but allow it to settle.
        if let info = try SocketSecurity.metadata(paths.socketPath),
           info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(),
           info.st_mode & 0o777 != 0o600 { return false }
        return try SocketIO.isReady(path: paths.socketPath, deadline: deadline)
    }

    private static func startupLog(_ paths: EnginePaths) -> URL {
        paths.directory.appendingPathComponent("startup.log")
    }

    private static func spawn(executableURL: URL, paths: EnginePaths) throws -> EngineChild {
        guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SocketTransportError.launchFailed(executableURL.path)
        }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SocketTransportError.launchFailed(L10n.text("protocol.launch.spawnAttributes", table: "ProtocolErrors")) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SocketTransportError.launchFailed(L10n.text("protocol.launch.spawnFileActions", table: "ProtocolErrors")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let logPath = startupLog(paths).path
        let log = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard log >= 0 else { throw SocketTransportError.systemCall("open startup log", errno) }
        defer { close(log) }
        var logInfo = stat()
        guard fstat(log, &logInfo) == 0, logInfo.st_mode & S_IFMT == S_IFREG,
              logInfo.st_uid == geteuid(), logInfo.st_mode & 0o777 == 0o600, logInfo.st_nlink == 1 else {
            throw SocketTransportError.unsafePath(logPath)
        }
        if logInfo.st_size > 1_048_576 { _ = ftruncate(log, 0) }
        // A new session and redirected stdio detach terminal lifetime/signals;
        // only startup diagnostics are retained in the private data directory.
        for result in [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO)
        ] where result != 0 {
            throw SocketTransportError.systemCall("spawn setup", result)
        }
        // Make the String-to-C-pointer bridge explicit across Swift toolchains.
        let argv: [UnsafeMutablePointer<CChar>?] = [executableURL.path, "--root", paths.directory.path].map { value in
            value.withCString { Darwin.strdup($0) }
        }
        let environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { entry in
            "\(entry.key)=\(entry.value)".withCString { Darwin.strdup($0) }
        }
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var arguments = argv + [nil]
        var env = environment + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executableURL.path, &actions, &attributes, &arguments, &env)
        guard result == 0 else { throw SocketTransportError.systemCall("posix_spawn", result) }
        let child = pid
        let state = EngineChild()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result < 0 && errno == EINTR
            if result == child { state.exited(status) }
        }
        return state
    }
}

private final class EngineChild: @unchecked Sendable {
    private let lock = NSLock()
    private var exitStatus: Int32?
    var status: Int32? { lock.withLock { exitStatus } }
    func exited(_ status: Int32) { lock.withLock { exitStatus = status } }
}
