import Darwin
import Foundation

public enum SocketTransportError: Error, LocalizedError, Sendable {
    case invalidPath(String), unsafePath(String), systemCall(String, Int32)
    case frameTooLarge(Int), timeout, disconnected, alreadyRunning, launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "Unix socket 경로가 올바르지 않거나 너무 깁니다: \(path)"
        case .unsafePath(let path): "현재 사용자 소유의 비공개 경로가 아닙니다: \(path)"
        case .systemCall(let operation, let code): "\(operation): \(String(cString: strerror(code))) (\(code))"
        case .frameTooLarge(let size): "IPC 프레임이 1 MiB 한도를 초과합니다: \(size)"
        case .timeout: "IPC 작업이 5초 안에 완료되지 않았습니다."
        case .disconnected: "IPC 연결이 완료 전에 닫혔습니다."
        case .alreadyRunning: "해당 데이터 경로의 엔진이 이미 실행 중입니다."
        case .launchFailed(let reason): "엔진을 시작할 수 없습니다: \(reason)"
        }
    }
}

public enum SocketTransport {
    public static let maximumFrameSize = 1_048_576
    public static let timeout: TimeInterval = 5

    public static func exchange(path: String, payload: Data) async throws -> Data {
        guard payload.count <= maximumFrameSize else { throw SocketTransportError.frameTooLarge(payload.count) }
        let operation = SocketOperation()
        return try await withTaskCancellationHandler {
            try await blockingIO {
                try operation.checkCancellation()
                _ = try SocketSecurity.validateSocket(path)
                let deadline = SocketIO.deadline()
                let fd = try SocketIO.makeSocket()
                try operation.register(fd)
                defer { operation.finish() }
                do {
                    try SocketIO.connect(fd, path: path, deadline: deadline)
                    try SocketIO.verifyPeer(fd)
                    try SocketIO.writeFrame(fd, payload: payload, deadline: deadline)
                    let result = try SocketIO.readFrame(fd, deadline: deadline)
                    try operation.checkCancellation()
                    return result
                } catch {
                    try operation.checkCancellation()
                    throw error
                }
            }
        } onCancel: { operation.cancel() }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private let listener: Int32
    private let socketIdentity: stat
    private let handler: @Sendable (Data) async -> Data
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var clients: [Int32: UUID] = [:]
    private let maximumClients = 16

    public init(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
        self.path = path
        self.handler = handler
        try SocketSecurity.validateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        guard try SocketSecurity.metadata(path) == nil else { throw SocketTransportError.unsafePath(path) }
        var address = try SocketIO.address(path)
        let addressLength = socklen_t(address.sun_len)
        let fd = try SocketIO.makeSocket()
        var createdIdentity: stat?
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, addressLength)
                }
            }
            guard result == 0 else { throw SocketTransportError.systemCall("bind", errno) }
            createdIdentity = try SocketSecurity.metadata(path)
            guard chmod(path, 0o600) == 0 else { throw SocketTransportError.systemCall("chmod socket", errno) }
            socketIdentity = try SocketSecurity.validateSocket(path)
            guard listen(fd, 16) == 0 else { throw SocketTransportError.systemCall("listen", errno) }
            listener = fd
        } catch {
            close(fd)
            if let createdIdentity, let current = try? SocketSecurity.metadata(path),
               current.st_dev == createdIdentity.st_dev, current.st_ino == createdIdentity.st_ino,
               current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == geteuid() {
                unlink(path)
            }
            throw error
        }
    }

    deinit {
        stop()
        close(listener)
    }

    public func run() async throws {
        let canStart = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard canStart else { throw SocketTransportError.alreadyRunning }
        try await withTaskCancellationHandler {
            try await blockingIO { try self.acceptLoop() }
        } onCancel: { self.stop() }
    }

    public func stop() {
        lock.withLock {
            stopped = true
            _ = shutdown(listener, SHUT_RDWR)
            for fd in clients.keys { _ = shutdown(fd, SHUT_RDWR) }
            if let current = try? SocketSecurity.metadata(path),
               current.st_dev == socketIdentity.st_dev, current.st_ino == socketIdentity.st_ino,
               current.st_mode & S_IFMT == S_IFSOCK {
                unlink(path)
            }
        }
    }

    private func acceptLoop() throws {
        defer { stop() }
        while !lock.withLock({ stopped }) {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if lock.withLock({ stopped }) { return }
            if result < 0 {
                if errno == EINTR { continue }
                throw SocketTransportError.systemCall("poll listener", errno)
            }
            if result == 0 { continue }
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if lock.withLock({ stopped }) { return }
                throw SocketTransportError.systemCall("accept", errno)
            }
            do {
                try SocketIO.configure(fd)
                try SocketIO.verifyPeer(fd)
            } catch {
                close(fd)
                continue
            }
            let clientID = UUID()
            let admitted = lock.withLock {
                guard !stopped, clients.count < maximumClients else { return false }
                clients[fd] = clientID
                return true
            }
            guard admitted else { close(fd); continue }
            Task { await self.serve(fd, clientID: clientID) }
        }
    }

    private func serve(_ fd: Int32, clientID: UUID) async {
        let deadline = SocketIO.deadline()
        let timer = Task {
            do { try await Task.sleep(for: .seconds(SocketTransport.timeout)) }
            catch { return }
            self.lock.withLock {
                if self.clients[fd] == clientID { _ = shutdown(fd, SHUT_RDWR) }
            }
        }
        defer {
            timer.cancel()
            lock.withLock {
                clients.removeValue(forKey: fd)
                close(fd)
            }
        }
        do {
            let input = try await blockingIO { try SocketIO.readFrame(fd, deadline: deadline) }
            let output = await handler(input)
            try await blockingIO { try SocketIO.writeFrame(fd, payload: output, deadline: deadline) }
        } catch {
            // The protocol owner encodes application errors. Invalid/truncated
            // transport input closes only this connection, never the listener.
        }
    }
}

private final class SocketOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    private var cancelled = false

    func register(_ descriptor: Int32) throws {
        try lock.withLock {
            guard !cancelled else { close(descriptor); throw CancellationError() }
            fd = descriptor
        }
    }

    func checkCancellation() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let fd { _ = shutdown(fd, SHUT_RDWR) }
        }
    }

    func finish() {
        lock.withLock {
            if let fd { close(fd) }
            fd = nil
        }
    }
}

func blockingIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

enum SocketIO {
    static var pathCapacity: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) }
    static func deadline(after seconds: TimeInterval = SocketTransport.timeout) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < pathCapacity else {
            throw SocketTransportError.invalidPath(path)
        }
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1)
        withUnsafeMutableBytes(of: &result.sun_path) { destination in
            destination.copyBytes(from: bytes + [0])
        }
        return result
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTransportError.systemCall("socket", errno) }
        do { try configure(fd); return fd }
        catch { close(fd); throw error }
    }

    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw SocketTransportError.systemCall("fcntl socket", errno)
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketTransportError.systemCall("SO_NOSIGPIPE", errno)
        }
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw SocketTransportError.systemCall("getpeereid", errno)
        }
        guard uid == geteuid() else { throw SocketTransportError.unsafePath("peer uid \(uid)") }
    }

    static func connect(_ fd: Int32, path: String, deadline: UInt64) throws {
        var destination = try address(path)
        let length = socklen_t(destination.sun_len)
        let result = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS || errno == EINTR || errno == EAGAIN else {
            throw SocketTransportError.systemCall("connect", errno)
        }
        try wait(fd, events: Int16(POLLOUT), deadline: deadline)
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else {
            throw SocketTransportError.systemCall("connect status", errno)
        }
        guard failure == 0 else { throw SocketTransportError.systemCall("connect", failure) }
    }

    static func isReady(path: String, deadline: UInt64) throws -> Bool {
        guard try SocketSecurity.metadata(path) != nil else { return false }
        _ = try SocketSecurity.validateSocket(path)
        let fd = try makeSocket()
        defer { close(fd) }
        do {
            try connect(fd, path: path, deadline: deadline)
            try verifyPeer(fd)
            return true
        } catch SocketTransportError.systemCall(_, let code) where code == ECONNREFUSED || code == ENOENT {
            return false
        }
    }

    static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SocketTransportError.timeout }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 { throw SocketTransportError.disconnected }
                return
            }
            if result == 0 { throw SocketTransportError.timeout }
            if errno != EINTR { throw SocketTransportError.systemCall("poll", errno) }
        }
    }

    static func readFrame(_ fd: Int32, deadline: UInt64) throws -> Data {
        let header = try readExactly(fd, count: 4, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count <= SocketTransport.maximumFrameSize else { throw SocketTransportError.frameTooLarge(count) }
        return try readExactly(fd, count: count, deadline: deadline)
    }

    static func writeFrame(_ fd: Int32, payload: Data, deadline: UInt64) throws {
        guard payload.count <= SocketTransport.maximumFrameSize else {
            throw SocketTransportError.frameTooLarge(payload.count)
        }
        let count = UInt32(payload.count)
        let header = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        try writeAll(fd, data: header, deadline: deadline)
        try writeAll(fd, data: payload, deadline: deadline)
    }

    static func readExactly(_ fd: Int32, count: Int, deadline: UInt64) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
                let received = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received > 0 { offset += received; continue }
                if received == 0 { throw SocketTransportError.disconnected }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw SocketTransportError.systemCall("recv", errno)
            }
        }
        return data
    }

    static func writeAll(_ fd: Int32, data: Data, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let written = send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if written > 0 { offset += written; continue }
                if written == 0 { throw SocketTransportError.disconnected }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw SocketTransportError.systemCall("send", errno)
            }
        }
    }
}
