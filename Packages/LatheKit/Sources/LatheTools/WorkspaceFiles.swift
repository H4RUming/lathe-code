import Darwin
import Foundation
import LatheLocalization

struct FileIdentity: Equatable, Sendable, CustomStringConvertible {
    let device: Int32
    let inode: UInt64
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    var description: String { "\(device):\(inode)" }
}

/// Every relative component is opened through a pinned directory FD without following links.
/// This constrains built-in file tools; approved shell commands are explicitly unsandboxed.
final class WorkspaceFiles {
    let root: URL
    let identity: FileIdentity
    private let rootFD: Int32
    private let protectedPaths: [String]

    init(root: URL, protectedPaths: [URL]) throws {
        self.root = root
        self.protectedPaths = protectedPaths.map { $0.path.lowercased() }
        guard !root.pathComponents.contains(where: { $0.lowercased() == ".git" }) else { throw ToolError.denied(L10n.errorText("workspace.gitRoot", table: "ToolMessages")) }
        let candidate = root.path.lowercased()
        guard !self.protectedPaths.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            throw ToolError.denied(L10n.errorText("workspace.protectedOverlap", table: "ToolMessages"))
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.open", table: "ToolMessages"), code) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let code = errno; close(fd); throw ToolError.io(L10n.errorText("workspace.operation.stat", table: "ToolMessages"), code) }
        rootFD = fd; identity = FileIdentity(info)
    }
    deinit { close(rootFD) }

    func validate(_ input: String, allowRoot: Bool = false) throws -> String {
        if input == ".", allowRoot { return input }
        guard !input.isEmpty, !input.hasPrefix("/"), !input.utf8.contains(0), input.utf8.count <= 4096 else {
            throw ToolError.denied(L10n.errorText("workspace.relativePath", table: "ToolMessages"))
        }
        let components = input.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw ToolError.denied(L10n.errorText("workspace.forbiddenPath", table: "ToolMessages"))
        }
        guard !isProtected(root.appendingPathComponent(input).path) else {
            throw ToolError.denied(L10n.errorText("workspace.protectedData", table: "ToolMessages"))
        }
        return input
    }

    func checkDirectory(_ path: String) throws { let fd = try directory(path); close(fd) }

    func directoryIdentity(_ path: String) throws -> FileIdentity {
        let fd = try directory(path); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.workingDirectory", table: "ToolMessages"), code) }
        return FileIdentity(info)
    }

    /// lstat-style validation does not open or read the target file. Approval
    /// preparation may inspect path/type/permissions, but never the body or SHA.
    func inspectFile(_ path: String, allowMissing: Bool = false) throws -> (isExecutable: Bool, exists: Bool) {
        let (parent, name) = try parentDirectory(path); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT, allowMissing { return (false, false) }
            let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.inspect", table: "ToolMessages"), code)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ToolError.denied(L10n.errorText("workspace.regularFile", table: "ToolMessages"))
        }
        return (info.st_mode & 0o111 != 0, true)
    }

    func read(_ path: String) throws -> Data {
        let (parent, name) = try parentDirectory(path); defer { close(parent) }
        return try read(parent: parent, name: name)
    }

    func checkPrecondition(_ path: String, expected: String) throws -> Data? {
        let (parent, name) = try parentDirectory(path); defer { close(parent) }
        return try checkPrecondition(parent: parent, name: name, expected: expected)
    }

    func list(_ path: String) throws -> [[String: String]] {
        let fd = try directory(path)
        guard let stream = fdopendir(fd) else { let code = errno; close(fd); throw ToolError.io(L10n.errorText("workspace.operation.list", table: "ToolMessages"), code) }
        defer { closedir(stream) }
        var entries: [[String: String]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.readEntry", table: "ToolMessages"), code) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.lowercased() == ".git" { continue }
            let relative = path == "." ? name : path + "/" + name
            if isProtected(root.appendingPathComponent(relative).path) { continue }
            guard entries.count < 2000 else { throw ToolError.invalid(L10n.errorText("workspace.directoryLimit", table: "ToolMessages")) }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.statEntry", table: "ToolMessages"), code) }
            let kind: String
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = "directory"
            case S_IFREG: kind = info.st_nlink == 1 ? "file" : "hardlink (blocked)"
            case S_IFLNK: kind = "symlink (blocked)"
            default: kind = "special (blocked)"
            }
            entries.append(["name": name, "type": kind])
        }
        return entries.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
    }

    func write(_ path: String, content: Data, expected: String) throws {
        let (parent, name) = try parentDirectory(path); defer { close(parent) }
        _ = try checkPrecondition(parent: parent, name: name, expected: expected)
        var prior = stat()
        let mode: mode_t = expected == "missing" ? 0o600 : {
            guard fstatat(parent, name, &prior, AT_SYMLINK_NOFOLLOW) == 0 else { return 0o600 }
            return prior.st_mode & 0o777
        }()
        let temporary = ".lathe-write-\(UUID().uuidString)"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.createAtomicWrite", table: "ToolMessages"), code) }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try content.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.write", table: "ToolMessages"), code) }
                offset += count
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.sync", table: "ToolMessages"), code) }
        try Task.checkCancellation()
        _ = try checkPrecondition(parent: parent, name: name, expected: expected)
        if expected == "missing" {
            guard linkat(parent, temporary, parent, name, 0) == 0 else {
                if errno == EEXIST { throw ToolError.preconditionChanged(L10n.errorText("workspace.appeared", table: "ToolMessages")) }
                let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.publish", table: "ToolMessages"), code)
            }
        } else {
            guard renameat(parent, temporary, parent, name) == 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.replace", table: "ToolMessages"), code) }
        }
        guard fsync(parent) == 0 else {
            throw ToolError.executionUnknown(L10n.errorFormat("workspace.syncAfterWrite", table: "ToolMessages", String(errno)))
        }
    }

    private func checkPrecondition(parent: Int32, name: String, expected: String) throws -> Data? {
        if expected == "missing" {
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw ToolError.preconditionChanged(L10n.errorText("workspace.alreadyExists", table: "ToolMessages")) }
            guard errno == ENOENT else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.checkNew", table: "ToolMessages"), code) }
            return nil
        }
        let data = try read(parent: parent, name: name)
        guard ToolBroker.digest(data) == expected else { throw ToolError.preconditionChanged(L10n.errorText("workspace.contentChanged", table: "ToolMessages")) }
        return data
    }

    private func read(parent: Int32, name: String) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.openNoLinks", table: "ToolMessages"), code) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.statFile", table: "ToolMessages"), code) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ToolError.denied(L10n.errorText("workspace.regularFile", table: "ToolMessages"))
        }
        guard info.st_size <= ToolBroker.fileLimit else { throw ToolError.invalid(L10n.errorText("workspace.fileLimit", table: "ToolMessages")) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.read", table: "ToolMessages"), code) }
            if count == 0 { break }
            guard count <= ToolBroker.fileLimit - result.count else { throw ToolError.invalid(L10n.errorText("workspace.fileLimit", table: "ToolMessages")) }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func directory(_ path: String) throws -> Int32 {
        _ = try validate(path, allowRoot: true)
        var current = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { let code = errno; throw ToolError.io(L10n.errorText("workspace.operation.duplicateDescriptor", table: "ToolMessages"), code) }
        if path == "." { return current }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(current)
            guard next >= 0 else { throw ToolError.io(L10n.errorText("workspace.operation.openDirectoryNoLinks", table: "ToolMessages"), code) }
            current = next
        }
        return current
    }

    private func parentDirectory(_ path: String) throws -> (Int32, String) {
        _ = try validate(path)
        var components = path.split(separator: "/").map(String.init)
        let name = components.removeLast()
        return (try directory(components.isEmpty ? "." : components.joined(separator: "/")), name)
    }

    private func isProtected(_ path: String) -> Bool {
        let candidate = path.lowercased()
        return protectedPaths.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
    }
}
