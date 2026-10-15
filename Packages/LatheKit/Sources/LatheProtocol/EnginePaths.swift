import CryptoKit
import Darwin
import Foundation

public struct EnginePaths: Sendable {
    public let directory: URL
    public let database: URL
    public let socketPath: String

    public init(root: URL? = nil) throws {
        let proposed = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Lathe", isDirectory: true)
        guard proposed.isFileURL else { throw SocketTransportError.invalidPath(proposed.absoluteString) }
        try SocketSecurity.ensurePrivateDirectory(proposed.path)
        directory = proposed.resolvingSymlinksInPath().standardizedFileURL
        database = directory.appendingPathComponent("lathe.sqlite")

        // Derive this from the data root even when explicitly supplied: a launched
        // engine receives --root and must find the same socket as its first client.
        let digest = SHA256.hash(data: Data(directory.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        var socketDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("lathe-\(digest)", isDirectory: true)
        if socketDirectory.appendingPathComponent("engine.sock").path.utf8.count >= SocketIO.pathCapacity {
            socketDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("lathe-\(geteuid())-\(digest)", isDirectory: true)
        }
        try SocketSecurity.ensurePrivateDirectory(socketDirectory.path)
        socketPath = socketDirectory.appendingPathComponent("engine.sock").path
        _ = try SocketIO.address(socketPath)
    }

    var engineLockPath: String { directory.appendingPathComponent("engine.lock").path }
    var bootstrapLockPath: String { directory.appendingPathComponent("bootstrap.lock").path }
}

enum SocketSecurity {
    static func metadata(_ path: String) throws -> stat? {
        var value = stat()
        if lstat(path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw SocketTransportError.systemCall("lstat", errno)
    }

    static func ensurePrivateDirectory(_ path: String) throws {
        // Foundation may create first and chmod afterwards. Another starter can
        // observe that intermediate mode, so set permissions in mkdir itself.
        try createMissingDirectories(path)
        try validateDirectory(path)
    }

    private static func createMissingDirectories(_ path: String) throws {
        if mkdir(path, 0o700) == 0 { return }
        let code = errno
        if code == EEXIST { return }
        guard code == ENOENT else { throw SocketTransportError.systemCall("mkdir", code) }
        let parent = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent().path
        guard parent != path else { throw SocketTransportError.systemCall("mkdir parent", code) }
        try createMissingDirectories(parent)
        if mkdir(path, 0o700) == 0 { return }
        guard errno == EEXIST else { throw SocketTransportError.systemCall("mkdir", errno) }
    }

    static func validateDirectory(_ path: String) throws {
        guard let info = try metadata(path),
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw SocketTransportError.unsafePath(path)
        }
    }

    static func validateSocket(_ path: String) throws -> stat {
        try validateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        guard let info = try metadata(path) else {
            throw SocketTransportError.systemCall("socket path", ENOENT)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else {
            throw SocketTransportError.unsafePath(path)
        }
        return info
    }

    static func openLock(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SocketTransportError.systemCall("open lock", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else {
            close(fd)
            throw SocketTransportError.unsafePath(path)
        }
        return fd
    }
}
