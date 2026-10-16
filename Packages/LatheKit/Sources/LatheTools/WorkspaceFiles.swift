import Darwin
import Foundation

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
        guard !root.pathComponents.contains(where: { $0.lowercased() == ".git" }) else { throw ToolError.denied("A .git directory cannot be a file-tool workspace.") }
        let candidate = root.path.lowercased()
        guard !self.protectedPaths.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            throw ToolError.denied("The workspace overlaps protected engine data.")
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError.io("open workspace", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let code = errno; close(fd); throw ToolError.io("stat workspace", code) }
        rootFD = fd; identity = FileIdentity(info)
    }
    deinit { close(rootFD) }

    func validate(_ input: String, allowRoot: Bool = false) throws -> String {
        if input == ".", allowRoot { return input }
        guard !input.isEmpty, !input.hasPrefix("/"), !input.utf8.contains(0), input.utf8.count <= 4096 else {
            throw ToolError.denied("Tool paths must be nonempty workspace-relative paths.")
        }
        let components = input.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw ToolError.denied("Path traversal, empty components and .git access are forbidden.")
        }
        guard !isProtected(root.appendingPathComponent(input).path) else {
            throw ToolError.denied("Engine state, credentials and execution records are protected.")
        }
        return input
    }

    func checkDirectory(_ path: String) throws { let fd = try directory(path); close(fd) }

    func directoryIdentity(_ path: String) throws -> FileIdentity {
        let fd = try directory(path); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ToolError.io("stat working directory", errno) }
        return FileIdentity(info)
    }

    /// lstat-style validation does not open or read the target file. Approval
    /// preparation may inspect path/type/permissions, but never the body or SHA.
    func inspectFile(_ path: String, allowMissing: Bool = false) throws -> (isExecutable: Bool, exists: Bool) {
        let (parent, name) = try parentDirectory(path); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT, allowMissing { return (false, false) }
            throw ToolError.io("inspect file without reading", errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ToolError.denied("Only regular files with one hard link can be read or replaced.")
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
        guard let stream = fdopendir(fd) else { let code = errno; close(fd); throw ToolError.io("list directory", code) }
        defer { closedir(stream) }
        var entries: [[String: String]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ToolError.io("read directory entry", errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.lowercased() == ".git" { continue }
            let relative = path == "." ? name : path + "/" + name
            if isProtected(root.appendingPathComponent(relative).path) { continue }
            guard entries.count < 2000 else { throw ToolError.invalid("Directory exceeds 2,000 entries; choose a smaller subdirectory.") }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ToolError.io("stat directory entry", errno) }
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
        guard fd >= 0 else { throw ToolError.io("create atomic write", errno) }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try content.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ToolError.io("write file", errno) }
                offset += count
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw ToolError.io("sync file", errno) }
        try Task.checkCancellation()
        _ = try checkPrecondition(parent: parent, name: name, expected: expected)
        if expected == "missing" {
            guard linkat(parent, temporary, parent, name, 0) == 0 else {
                if errno == EEXIST { throw ToolError.preconditionChanged("The file appeared after preparation.") }
                throw ToolError.io("publish new file", errno)
            }
        } else {
            guard renameat(parent, temporary, parent, name) == 0 else { throw ToolError.io("replace file", errno) }
        }
        guard fsync(parent) == 0 else {
            throw ToolError.executionUnknown("File replacement occurred, but syncing its directory failed (errno \(errno)).")
        }
    }

    private func checkPrecondition(parent: Int32, name: String, expected: String) throws -> Data? {
        if expected == "missing" {
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw ToolError.preconditionChanged("The file already exists; read its current SHA-256 before replacing it.") }
            guard errno == ENOENT else { throw ToolError.io("check new file", errno) }
            return nil
        }
        let data = try read(parent: parent, name: name)
        guard ToolBroker.digest(data) == expected else { throw ToolError.preconditionChanged("File content changed; read it again before writing.") }
        return data
    }

    private func read(parent: Int32, name: String) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError.io("open file without following links", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ToolError.io("stat file", errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ToolError.denied("Only regular files with one hard link can be read or replaced.")
        }
        guard info.st_size <= ToolBroker.fileLimit else { throw ToolError.invalid("File exceeds 256 KiB.") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ToolError.io("read file", errno) }
            if count == 0 { break }
            guard count <= ToolBroker.fileLimit - result.count else { throw ToolError.invalid("File exceeds 256 KiB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func directory(_ path: String) throws -> Int32 {
        _ = try validate(path, allowRoot: true)
        var current = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw ToolError.io("duplicate workspace descriptor", errno) }
        if path == "." { return current }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(current)
            guard next >= 0 else { throw ToolError.io("open directory without following links", code) }
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
