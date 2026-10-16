import CryptoKit
import Darwin
import Foundation
import LatheDomain
import LatheLocalization

/// Content-addressed, bounded private artifacts. Publication never overwrites an
/// existing digest. Each read verifies bytes rather than trusting the filename.
public final class BlobStore: @unchecked Sendable {
    private let directory: Int32
    public let maxBytes: Int

    public init(root: URL, maxBytes: Int = 8 * 1_024 * 1_024) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), (1...64 * 1_024 * 1_024).contains(maxBytes) else {
            throw LatheError.invalidRequest(L10n.text("storage.blob.invalidConfiguration", table: "StorageErrors"))
        }
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST {
            throw LatheError.storage(L10n.format("storage.blob.createDirectoryFailed", table: "StorageErrors", errno))
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LatheError.storage(L10n.format("storage.blob.openDirectoryFailed", table: "StorageErrors", errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            close(descriptor)
            throw LatheError.storage(L10n.text("storage.blob.invalidDirectoryPermissions", table: "StorageErrors"))
        }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            close(descriptor)
            throw LatheError.storage(L10n.format("storage.blob.openParentFailed", table: "StorageErrors", errno))
        }
        let synced = fsync(parent)
        let syncError = errno
        close(parent)
        guard synced == 0 else {
            close(descriptor)
            throw LatheError.storage(L10n.format("storage.blob.syncParentFailed", table: "StorageErrors", syncError))
        }
        self.directory = descriptor
        self.maxBytes = maxBytes
    }

    deinit { close(directory) }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        guard data.count <= maxBytes else { throw LatheError.invalidRequest(L10n.text("storage.blob.sizeLimit", table: "StorageErrors")) }
        let id = Self.digest(data)
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LatheError.storage(L10n.format("storage.blob.createTemporaryFailed", table: "StorageErrors", errno)) }
        defer {
            close(descriptor)
            _ = unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LatheError.storage(L10n.format("storage.blob.writeFailed", table: "StorageErrors", errno)) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw LatheError.storage(L10n.format("storage.blob.syncFileFailed", table: "StorageErrors", errno)) }
        if linkat(directory, temporary, directory, id, 0) != 0 {
            guard errno == EEXIST else { throw LatheError.storage(L10n.format("storage.blob.publishFailed", table: "StorageErrors", errno)) }
            // Refuse tampered or symlink destinations; never repair by overwrite.
            guard try read(id) == data else { throw LatheError.storage(L10n.text("storage.blob.existingContentMismatch", table: "StorageErrors")) }
        }
        guard unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 else {
            throw LatheError.storage(L10n.format("storage.blob.syncDirectoryFailed", table: "StorageErrors", errno))
        }
        return id
    }

    public func read(_ id: String) throws -> Data {
        guard Self.validID(id) else { throw LatheError.invalidRequest(L10n.text("storage.blob.invalidID", table: "StorageErrors")) }
        // NONBLOCK ensures replacing a blob with a FIFO cannot block the engine.
        let descriptor = openat(directory, id, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw LatheError.storage(L10n.format("storage.blob.openFileFailed", table: "StorageErrors", errno)) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0, info.st_size <= maxBytes else {
            throw LatheError.storage(L10n.text("storage.blob.invalidFile", table: "StorageErrors"))
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LatheError.storage(L10n.format("storage.blob.readFailed", table: "StorageErrors", errno)) }
            if count == 0 { break }
            guard data.count <= maxBytes - count else { throw LatheError.storage(L10n.text("storage.blob.sizeLimit", table: "StorageErrors")) }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count == info.st_size, Self.digest(data) == id else {
            throw LatheError.storage(L10n.text("storage.blob.integrityFailed", table: "StorageErrors"))
        }
        return data
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
