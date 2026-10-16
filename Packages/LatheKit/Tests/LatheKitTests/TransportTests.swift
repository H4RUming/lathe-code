import Darwin
import Foundation
@testable import LatheProtocol
import Testing

private struct TransportFixture: Sendable {
    let root: URL
    let paths: EnginePaths

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("lathe-transport-\(UUID().uuidString)", isDirectory: true)
        paths = try EnginePaths(root: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths.socketPath).deletingLastPathComponent())
    }
}

@Suite struct TransportTests {
    @Test func roundTripsEmptyUnicodeAndMaximumFramesConcurrently() async throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let server = try UnixSocketServer(path: fixture.paths.socketPath) { $0 }
        let running = Task { try await server.run() }
        defer { server.stop() }
        let payloads = [Data(), Data("한글 🧵".utf8), Data(repeating: 0xAB, count: SocketTransport.maximumFrameSize)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    let output = try await SocketTransport.exchange(path: fixture.paths.socketPath, payload: payload)
                    #expect(output == payload)
                }
            }
            try await group.waitForAll()
        }
        let socket = try SocketSecurity.validateSocket(fixture.paths.socketPath)
        #expect(socket.st_uid == geteuid())
        #expect(socket.st_mode & 0o777 == 0o600)
        server.stop()
        try await running.value
    }

    @Test func fragmentedHeaderAndBodyAreReassembled() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let reader = pair[0], writer = pair[1]
        defer { close(reader); close(writer) }
        try SocketIO.configure(reader)
        try SocketIO.configure(writer)
        let payload = Data("분할된 frame".utf8)
        let length = UInt32(payload.count)
        let bytes = Data([0, 0, 0, UInt8(length)]) + payload
        async let input: Data = blockingIO { try SocketIO.readFrame(reader, deadline: SocketIO.deadline()) }
        try await blockingIO {
            for byte in bytes {
                try SocketIO.writeAll(writer, data: Data([byte]), deadline: SocketIO.deadline())
                usleep(1_000)
            }
        }
        #expect(try await input == payload)
    }

    @Test func oversizedAndTruncatedRequestsDoNotTerminateListener() async throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let server = try UnixSocketServer(path: fixture.paths.socketPath) { $0 }
        let running = Task { try await server.run() }
        defer { server.stop() }
        for bytes in [Data([0, 16, 0, 1]), Data([0, 0, 0, 10, 1, 2])] {
            try await blockingIO {
                let fd = try SocketIO.makeSocket()
                defer { close(fd) }
                try SocketIO.connect(fd, path: fixture.paths.socketPath, deadline: SocketIO.deadline())
                try SocketIO.writeAll(fd, data: bytes, deadline: SocketIO.deadline())
                _ = shutdown(fd, SHUT_WR)
                do {
                    _ = try SocketIO.readFrame(fd, deadline: SocketIO.deadline())
                    Issue.record("잘못된 프레임에 정상 응답이 반환되었습니다.")
                } catch SocketTransportError.disconnected { }
            }
        }
        let payload = Data("still alive".utf8)
        #expect(try await SocketTransport.exchange(path: fixture.paths.socketPath, payload: payload) == payload)
        do {
            _ = try await SocketTransport.exchange(path: fixture.paths.socketPath,
                payload: Data(count: SocketTransport.maximumFrameSize + 1))
            Issue.record("1 MiB 초과 요청이 허용되었습니다.")
        } catch SocketTransportError.frameTooLarge { }
        server.stop()
        try await running.value
    }

    @Test func deadlineAndShutdownReturnErrorsWithoutSignals() async throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let reader = pair[0], writer = pair[1]
        defer { close(reader); close(writer) }
        try SocketIO.configure(reader)
        try SocketIO.configure(writer)
        do {
            _ = try SocketIO.readFrame(reader, deadline: SocketIO.deadline(after: 0.05))
            Issue.record("응답 없는 peer의 deadline이 무시되었습니다.")
        } catch SocketTransportError.timeout { }
        // Closing a peer descriptor does not guarantee the endpoint is gone:
        // another process may briefly hold a reference during parallel spawn.
        // Explicitly shut down this endpoint's write side to exercise EPIPE
        // and SO_NOSIGPIPE independently of descriptor lifetime elsewhere.
        try #require(shutdown(reader, SHUT_WR) == 0)
        do {
            try SocketIO.writeFrame(reader, payload: Data([1]), deadline: SocketIO.deadline())
            Issue.record("shutdown한 쓰기 방향에 쓰기가 성공했습니다.")
        } catch SocketTransportError.systemCall(_, let code) {
            #expect(code == EPIPE)
        }
    }

    @Test func cancellationInterruptsPendingRead() async throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let server = try UnixSocketServer(path: fixture.paths.socketPath) { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return Data()
        }
        let running = Task { try await server.run() }
        defer { server.stop() }
        let request = Task { try await SocketTransport.exchange(path: fixture.paths.socketPath, payload: Data()) }
        try await Task.sleep(for: .milliseconds(30))
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("취소된 연결이 결과를 반환했습니다.")
        } catch is CancellationError { }
        server.stop()
        try await running.value
    }

    @Test func engineLeaseIsExclusiveAndCanBeReacquired() throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        var first: EngineLease? = try EngineLease(paths: fixture.paths)
        weak var original = first
        _ = withExtendedLifetime(first) {
            #expect(throws: SocketTransportError.self) { try EngineLease(paths: fixture.paths) }
        }
        first = nil
        #expect(original == nil)
        let second = try EngineLease(paths: fixture.paths)
        withExtendedLifetime(second) {}
    }

    @Test func engineLeaseReleaseDoesNotWaitForDuplicatedDescriptorToClose() throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        var first: EngineLease? = try EngineLease(paths: fixture.paths)
        weak var original = first
        // dup and fork share the same flock. Keep a duplicate alive to model
        // a concurrent spawn before exec closes its inherited CLOEXEC handles.
        let descriptor = try #require(first?.descriptor)
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        try #require(duplicate >= 0)
        defer { close(duplicate) }
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        first = nil
        #expect(original == nil)
        #expect(fcntl(duplicate, F_GETFD) >= 0)

        let replacement = try EngineLease(paths: fixture.paths)
        _ = withExtendedLifetime(replacement) {
            #expect(throws: SocketTransportError.self) { try EngineLease(paths: fixture.paths) }
        }
    }

    @Test func staleSocketIsCleanedOnlyByLeaseAndLiveSocketIsPreserved() async throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let fd = try SocketIO.makeSocket()
        var address = try SocketIO.address(fixture.paths.socketPath)
        let length = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        #expect(bound == 0)
        #expect(chmod(fixture.paths.socketPath, 0o600) == 0)
        close(fd)
        #expect(try SocketSecurity.metadata(fixture.paths.socketPath) != nil)
        do {
            let lease = try EngineLease(paths: fixture.paths)
            #expect(try SocketSecurity.metadata(fixture.paths.socketPath) == nil)
            withExtendedLifetime(lease) {}
        }
        let server = try UnixSocketServer(path: fixture.paths.socketPath) { $0 }
        let running = Task { try await server.run() }
        defer { server.stop() }
        #expect(throws: SocketTransportError.self) { try EngineLease(paths: fixture.paths) }
        #expect(try SocketSecurity.metadata(fixture.paths.socketPath) != nil)
        #expect(try await SocketTransport.exchange(path: fixture.paths.socketPath, payload: Data([4])) == Data([4]))
        server.stop()
        try await running.value
    }

    @Test func unsafeSocketSymlinkAndDirectoryPermissionsAreRejected() throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: fixture.paths.socketPath, withDestinationPath: target.path)
        #expect(throws: SocketTransportError.self) { try EngineLease(paths: fixture.paths) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect((try SocketSecurity.metadata(fixture.paths.socketPath)?.st_mode ?? 0) & S_IFMT == S_IFLNK)
        #expect(chmod(fixture.root.path, 0o755) == 0)
        #expect(throws: SocketTransportError.self) { try EnginePaths(root: fixture.root) }
    }

    @Test func pathsStayShortAndConsistentForExplicitDataRoot() throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let longRoot = fixture.root.appendingPathComponent(String(repeating: "x", count: 120))
        let first = try EnginePaths(root: longRoot)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: first.socketPath).deletingLastPathComponent()) }
        let second = try EnginePaths(root: first.directory)
        #expect(first.socketPath == second.socketPath)
        #expect(first.socketPath.utf8.count < SocketIO.pathCapacity)
        #expect(first.database == second.database)
        #expect(throws: SocketTransportError.self) { try SocketIO.address("/" + String(repeating: "x", count: 110)) }
    }

    @Test func simultaneousPathInitializationNeverPublishesBroadPermissions() async throws {
        for _ in 0..<12 {
            let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("lathe-path-race-\(UUID().uuidString)", isDirectory: true)
            let root = base.appendingPathComponent("nested/data", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let paths = try await withThrowingTaskGroup(of: EnginePaths.self, returning: [EnginePaths].self) { group in
                for _ in 0..<16 { group.addTask { try EnginePaths(root: root) } }
                var results: [EnginePaths] = []
                for try await result in group { results.append(result) }
                return results
            }
            let first = try #require(paths.first)
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: first.socketPath).deletingLastPathComponent()) }
            #expect(paths.count == 16)
            #expect(paths.allSatisfy { $0.directory == first.directory && $0.socketPath == first.socketPath })
            try SocketSecurity.validateDirectory(first.directory.path)
            try SocketSecurity.validateDirectory(URL(fileURLWithPath: first.socketPath).deletingLastPathComponent().path)
        }
    }

    @Test func bootstrapAttachesToLiveEngineWithoutLaunchingReplacement() async throws {
        let fixture = try TransportFixture()
        defer { fixture.cleanup() }
        let lease = try EngineLease(paths: fixture.paths)
        let server = try UnixSocketServer(path: fixture.paths.socketPath) { $0 }
        let running = Task { try await server.run() }
        defer { server.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await EngineBootstrap.ensureRunning(paths: fixture.paths,
                        executableURL: URL(fileURLWithPath: "/nonexistent/never-launch"))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await SocketTransport.exchange(path: fixture.paths.socketPath, payload: Data([7])) == Data([7]))
        server.stop()
        try await running.value
        withExtendedLifetime(lease) {}
    }
}
