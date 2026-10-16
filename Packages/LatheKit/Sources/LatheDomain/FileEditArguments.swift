/// A proposed single replacement. Decoding these arguments does not verify the
/// current file; the tool validates its hash and exact UTF-8 bytes after approval.
public struct FileEditArguments: Codable, Equatable, Sendable {
    public let path: String
    public let oldText: String
    public let newText: String
    public let expectedSHA256: String

    public init(path: String, oldText: String, newText: String, expectedSHA256: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.expectedSHA256 = expectedSHA256
    }
}
