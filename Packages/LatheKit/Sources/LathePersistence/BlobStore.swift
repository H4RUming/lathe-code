import CryptoKit
import Darwin
import Foundation
import LatheDomain

/// Content-addressed, bounded private artifacts. Publication never overwrites an
/// existing digest. Each read verifies bytes rather than trusting the filename.
public final class BlobStore: @unchecked Sendable {
    private let directory: Int32
    public let maxBytes: Int

    public init(root: URL, maxBytes: Int = 8 * 1_024 * 1_024) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), (1...64 * 1_024 * 1_024).contains(maxBytes) else {
            throw LatheError.invalidRequest("Blob 저장소 경로 또는 크기 제한이 올바르지 않습니다.")
        }
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST {
            throw Self.io("Blob 디렉터리 생성 실패")
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.io("Blob 디렉터리 열기 실패") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            close(descriptor)
            throw LatheError.storage("Blob 디렉터리는 현재 사용자 소유의 0700 디렉터리여야 합니다.")
        }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            close(descriptor)
            throw Self.io("Blob 상위 디렉터리 열기 실패")
        }
        let synced = fsync(parent)
        let syncError = errno
        close(parent)
        guard synced == 0 else {
            close(descriptor)
            throw LatheError.storage("Blob 상위 디렉터리 동기화 실패 (errno \(syncError))")
        }
        self.directory = descriptor
        self.maxBytes = maxBytes
    }

    deinit { close(directory) }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        guard data.count <= maxBytes else { throw LatheError.invalidRequest("Blob 크기 제한을 초과했습니다.") }
        let id = Self.digest(data)
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.io("Blob 임시 파일 생성 실패") }
        defer {
            close(descriptor)
            _ = unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.io("Blob 쓰기 실패") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Self.io("Blob 파일 동기화 실패") }
        if linkat(directory, temporary, directory, id, 0) != 0 {
            guard errno == EEXIST else { throw Self.io("Blob 발행 실패") }
            // Refuse tampered or symlink destinations; never repair by overwrite.
            guard try read(id) == data else { throw LatheError.storage("기존 Blob과 내용이 일치하지 않습니다.") }
        }
        guard unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 else {
            throw Self.io("Blob 디렉터리 동기화 실패")
        }
        return id
    }

    public func read(_ id: String) throws -> Data {
        guard Self.validID(id) else { throw LatheError.invalidRequest("Blob 식별자가 올바르지 않습니다.") }
        // NONBLOCK ensures replacing a blob with a FIFO cannot block the engine.
        let descriptor = openat(directory, id, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.io("Blob 파일 열기 실패") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0, info.st_size <= maxBytes else {
            throw LatheError.storage("Blob 파일의 형식, 권한 또는 크기가 올바르지 않습니다.")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Self.io("Blob 읽기 실패") }
            if count == 0 { break }
            guard data.count <= maxBytes - count else { throw LatheError.storage("Blob 크기 제한을 초과했습니다.") }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count == info.st_size, Self.digest(data) == id else {
            throw LatheError.storage("Blob 내용의 무결성 검증에 실패했습니다.")
        }
        return data
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func io(_ context: String) -> LatheError {
        .storage("\(context) (errno \(errno))")
    }
}
