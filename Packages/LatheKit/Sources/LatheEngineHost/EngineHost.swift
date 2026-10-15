import Darwin
import Foundation
import LatheDomain
import LatheProtocol
import LatheProviders
import LatheRuntime

/// An engine whose lifetime belongs to the containing application. It never
/// launches or attaches to a separate engine process. The development harness
/// uses this same host explicitly, outside the distributed app.
public actor EngineHost {
    private enum Phase { case idle, running, stopping, stopped }
    private struct Resources: Sendable {
        let generation: UUID
        let runtime: EngineRuntime
        let service: EngineService
        let server: UnixSocketServer
        let listener: Task<Void, Error>
        let info: EngineInfo
    }

    private let paths: EnginePaths
    private let runnerURL: URL
    private let credentials: any CredentialStore
    private let modelClient: ModelClient
    private let chunkDelay: Duration
    private var phase = Phase.idle
    private var lease: EngineLease?
    private var resources: Resources?
    private var stoppingTask: Task<Void, Never>?
    private var failure: (any Error)?
    private var stoppedWaiters: [CheckedContinuation<Void, Error>] = []

    public init(paths: EnginePaths, runnerURL: URL, credentials: any CredentialStore = KeychainCredentialStore(),
                modelClient: ModelClient = ModelClient(), chunkDelay: Duration = .milliseconds(120)) {
        self.paths = paths; self.runnerURL = runnerURL
        self.credentials = credentials; self.modelClient = modelClient; self.chunkDelay = chunkDelay
    }

    /// Acquisition, runtime creation and socket publication do not suspend, so
    /// stop racing startup runs after either complete startup or complete failure.
    /// Another owner's lease always fails; there is no attach fallback.
    @discardableResult
    public func start() async throws -> EngineInfo {
        try Task.checkCancellation()
        if phase == .running, let resources { return resources.info }
        guard phase == .idle else { throw LatheError.conflict("종료 중이거나 종료된 앱 엔진은 다시 시작할 수 없습니다.") }
        guard runnerURL.isFileURL, runnerURL.path.hasPrefix("/") else {
            throw LatheError.invalidRequest("runner의 절대 파일 경로가 필요합니다.")
        }
        let acquiredLease = try EngineLease(paths: paths)
        let runtime = try EngineRuntime(databaseURL: paths.database, chunkDelay: chunkDelay, runnerURL: runnerURL,
                                        credentials: credentials, modelClient: modelClient)
        let info = EngineInfo(processID: getpid(), engineID: UUID(), mode: "coding-preview")
        let service = EngineService(runtime: runtime, info: info)
        let server = try UnixSocketServer(path: paths.socketPath) { await service.handle($0) }
        let listener = Task { try await server.run() }
        let generation = UUID()
        lease = acquiredLease
        resources = Resources(generation: generation, runtime: runtime, service: service, server: server, listener: listener, info: info)
        failure = nil
        phase = .running
        Task { [weak self] in
            let result = await listener.result
            await self?.listenerEnded(generation: generation, result: result)
        }
        return info
    }

    /// Concurrent callers await the same cleanup. Admission closes before any
    /// worker is cancelled, and the lease is retained through runner cleanup and
    /// all previously admitted RPCs. Returning means another host can acquire it.
    public func stop() async {
        guard let current = resources else {
            phase = .stopped
            resumeStoppedWaiters()
            return
        }
        let cleanup: Task<Void, Never>
        if let stoppingTask { cleanup = stoppingTask }
        else {
            phase = .stopping
            cleanup = Task {
                await current.service.closeAdmission()
                current.server.stop()
                await current.runtime.shutdown()
                await current.service.drain()
                _ = await current.listener.result
            }
            stoppingTask = cleanup
        }
        await cleanup.value
        // Another stop caller may already have finished this generation.
        guard resources?.generation == current.generation else { return }
        resources = nil
        stoppingTask = nil
        lease = nil
        phase = .stopped
        resumeStoppedWaiters()
    }

    /// Used by the explicit developer harness. Apps own start/stop directly.
    public func waitUntilStopped() async throws {
        if phase == .idle || phase == .stopped {
            if let failure { throw failure }
            return
        }
        try await withCheckedThrowingContinuation { stoppedWaiters.append($0) }
    }

    private func listenerEnded(generation: UUID, result: Result<Void, Error>) async {
        guard resources?.generation == generation, phase == .running else { return }
        switch result {
        case .failure(let error): failure = error
        case .success: failure = LatheError.transport("앱 엔진의 listener가 예기치 않게 종료되었습니다.")
        }
        await stop()
    }

    private func resumeStoppedWaiters() {
        let waiters = stoppedWaiters
        stoppedWaiters.removeAll()
        for waiter in waiters {
            if let failure { waiter.resume(throwing: failure) }
            else { waiter.resume() }
        }
    }

    deinit {
        // Explicit stop is required before application termination. This is a
        // best-effort backstop for an owner that releases an otherwise live host.
        guard let current = resources else { return }
        let heldLease = lease
        Task {
            await current.service.closeAdmission()
            current.server.stop()
            await current.runtime.shutdown()
            await current.service.drain()
            _ = await current.listener.result
            withExtendedLifetime(heldLease) {}
        }
    }
}
