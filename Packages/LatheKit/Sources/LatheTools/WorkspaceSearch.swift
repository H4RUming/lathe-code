import CoreFoundation
import Darwin
import Foundation
import LatheLocalization

struct SearchRequest: Sendable {
    let path: String
    let nameGlob: String
    let includeHidden: Bool
    let offset: Int
    let limit: Int
    let query: String?
    let caseSensitive: Bool

    init(object: [String: Any], content: Bool) throws {
        func integer(_ key: String, range: ClosedRange<Int>) throws -> Int {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  Double(range.lowerBound)...Double(range.upperBound) ~= value.doubleValue else {
                throw ToolError.invalid(L10n.errorText("search.invalidArguments", table: "ToolMessages"))
            }
            return value.intValue
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ToolError.invalid(L10n.errorText("search.invalidArguments", table: "ToolMessages"))
            }
            return value.boolValue
        }
        guard let path = object["path"] as? String, let glob = object["nameGlob"] as? String,
              !glob.isEmpty, glob.utf8.count <= 128, !glob.contains("/"), !glob.utf8.contains(0) else {
            throw ToolError.invalid(L10n.errorText("search.invalidGlob", table: "ToolMessages"))
        }
        self.path = path; nameGlob = glob
        includeHidden = try boolean("includeHidden")
        offset = try integer("offset", range: 0...1000)
        limit = try integer("limit", range: 1...100)
        caseSensitive = content ? try boolean("caseSensitive") : true
        if content {
            guard let query = object["query"] as? String, !query.isEmpty, query.utf8.count <= 256,
                  !query.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
                throw ToolError.invalid(L10n.errorText("search.invalidQuery", table: "ToolMessages"))
            }
            self.query = query
        } else { query = nil }
        let components = path == "." ? [] : path.split(separator: "/").map(String.init)
        guard !components.contains(where: { WorkspaceSearch.excludedDirectories.contains($0.lowercased()) }),
              includeHidden || !components.contains(where: { $0.hasPrefix(".") }) else {
            throw ToolError.invalid(L10n.errorText("search.excludedRoot", table: "ToolMessages"))
        }
    }
}

/// Native, bounded discovery. No shell, regex engine, git process or ignore-file
/// content is consulted. A search is approved as a recursive read operation.
enum WorkspaceSearch {
    static let excludedDirectories: Set<String> = [".build", "node_modules", "vendor", ".venv", "venv", "build", "dist", "target"]
    struct Limits: Sendable {
        var entries = 10_000
        var files = 2_000
        var readBytes = 8 * 1_024 * 1_024
        var fileBytes = 262_144
        var depth = 32
        var seconds: Double = 5
        var outputBytes = 49_152
    }
    // Internal task-scoped limits allow deterministic boundary tests without
    // changing product limits or process-global state.
    @TaskLocal static var limitsOverride: Limits?

    static func execute(_ request: SearchRequest, access: WorkspaceFiles, directory: Int32) async throws -> ToolResult {
        try await Scanner(request: request, access: access, limits: limitsOverride ?? Limits()).run(directory: directory)
    }

    /// Only '*' and '?' have special meaning; all other characters are literal.
    /// Character comparison also respects canonically equivalent Unicode names.
    static func matches(_ name: String, glob: String) -> Bool {
        let value = Array(name), pattern = Array(glob)
        var index = 0, token = 0, star: Int?, retry = 0
        while index < value.count {
            if token < pattern.count, pattern[token] == "*" {
                star = token; token += 1; retry = index
            } else if token < pattern.count, pattern[token] == "?" || pattern[token] == value[index] {
                index += 1; token += 1
            } else if let star {
                retry += 1; index = retry; token = star + 1
            } else { return false }
        }
        while token < pattern.count, pattern[token] == "*" { token += 1 }
        return token == pattern.count
    }

    private final class Scanner {
        let request: SearchRequest
        let access: WorkspaceFiles
        let limits: Limits
        let deadline: ContinuousClock.Instant
        var entriesVisited = 0, filesRead = 0, bytesRead = 0, matchesSeen = 0
        var matches: [[String: Any]] = []
        var skipped: [String: Int] = [:]
        var stopReason: String?
        var ticks = 0

        init(request: SearchRequest, access: WorkspaceFiles, limits: Limits) {
            self.request = request; self.access = access; self.limits = limits
            deadline = .now + .seconds(limits.seconds)
        }

        func run(directory: Int32) async throws -> ToolResult {
            try await walk(directory: directory, path: request.path, depth: 0)
            try Task.checkCancellation()
            let data = try encoded()
            guard data.count <= limits.outputBytes else {
                throw ToolError.invalid(L10n.errorText("search.metadataLimit", table: "ToolMessages"))
            }
            return ToolResult(output: String(decoding: data, as: UTF8.self), isError: false, rawOutput: data)
        }

        func checkpoint() async throws -> Bool {
            try Task.checkCancellation()
            ticks += 1
            if ticks % 64 == 0 { await Task.yield(); try Task.checkCancellation() }
            if stopReason != nil { return false }
            if .now >= deadline { stopReason = "timeLimit"; return false }
            return true
        }

        func skip(_ reason: String) { skipped[reason, default: 0] += 1 }

        func walk(directory: Int32, path: String, depth: Int) async throws {
            guard try await checkpoint() else { return }
            let copy = fcntl(directory, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { skip("unreadable"); return }
            guard let stream = fdopendir(copy) else { close(copy); skip("unreadable"); return }
            // Close the stream before descending so only the pinned directory FD
            // is retained at each depth. Names are sorted without locale collation.
            var names: [String] = []
            do {
                defer { closedir(stream) }
                while try await checkpoint() {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        if errno != 0 { skip("unreadable") }
                        break
                    }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                            String(validatingUTF8: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    guard entriesVisited < limits.entries else { stopReason = "entryLimit"; break }
                    entriesVisited += 1
                    guard let name else { skip("invalidName"); continue }
                    names.append(name)
                }
            }
            for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard try await checkpoint() else { return }
                let relative = path == "." ? name : path + "/" + name
                if name.lowercased() == ".git" { skip("git"); continue }
                if !access.searchPathAllowed(relative) { skip("protectedOrInvalidPath"); continue }
                if !request.includeHidden && name.hasPrefix(".") { skip("hidden"); continue }
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { skip("unreadable"); continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if WorkspaceSearch.excludedDirectories.contains(name.lowercased()) { skip("generatedDirectory"); continue }
                    guard depth < limits.depth else { stopReason = "depthLimit"; return }
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { skip("unreadable"); continue }
                    do {
                        defer { close(child) }
                        var opened = stat()
                        guard fstat(child, &opened) == 0, FileIdentity(opened) == FileIdentity(info) else { skip("changed"); continue }
                        try await walk(directory: child, path: relative, depth: depth + 1)
                    }
                case S_IFREG:
                    guard info.st_nlink == 1 else { skip("hardlink"); continue }
                    guard WorkspaceSearch.matches(name, glob: request.nameGlob) else { continue }
                    if let query = request.query {
                        if let data = try await readFile(parent: directory, name: name, expected: info) {
                            try await search(data, path: relative, query: query)
                        }
                    } else { try add(["path": relative]) }
                case S_IFLNK: skip("symlink")
                default: skip("special")
                }
            }
        }

        func readFile(parent: Int32, name: String, expected: stat) async throws -> Data? {
            guard expected.st_size >= 0, expected.st_size <= limits.fileBytes else { skip("tooLarge"); return nil }
            guard filesRead < limits.files else { stopReason = "fileLimit"; return nil }
            guard expected.st_size <= limits.readBytes - bytesRead else { stopReason = "byteLimit"; return nil }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { skip("unreadable"); return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  FileIdentity(info) == FileIdentity(expected) else { skip("changed"); return nil }
            guard info.st_size >= 0, info.st_size <= limits.fileBytes else { skip("tooLarge"); return nil }
            guard info.st_size <= limits.readBytes - bytesRead else { stopReason = "byteLimit"; return nil }
            filesRead += 1
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while try await checkpoint() {
                // Read exactly the pinned file's advertised size, with a global
                // byte cap. A post-read stat rejects growth/truncation or edits.
                let remaining = Int(info.st_size) - data.count
                if remaining == 0 { break }
                let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { skip("changedOrUnreadable"); return nil }
                bytesRead += count
                data.append(contentsOf: buffer.prefix(count))
            }
            guard stopReason == nil else { return nil }
            var final = stat()
            guard fstat(fd, &final) == 0, final.st_nlink == 1, final.st_size == info.st_size,
                  final.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  final.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { skip("changed"); return nil }
            if data.contains(0) { skip("binary"); return nil }
            guard String(data: data, encoding: .utf8) != nil else { skip("invalidUTF8"); return nil }
            return data
        }

        func search(_ data: Data, path: String, query: String) async throws {
            let hash = ToolBroker.digest(data)
            let options: String.CompareOptions = request.caseSensitive ? [] : [.caseInsensitive]
            // Byte splitting handles CRLF independently of Swift grapheme rules.
            for (index, bytes) in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                guard try await checkpoint() else { return }
                let line = String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes[...], as: UTF8.self)
                guard let match = line.range(of: query, options: options, locale: Locale(identifier: "en_US_POSIX")) else { continue }
                var start = match.lowerBound, prefixBytes = 0
                while start > line.startIndex {
                    let previous = line.unicodeScalars.index(before: start)
                    let count = line[previous..<start].utf8.count
                    if prefixBytes + count > 128 { break }
                    prefixBytes += count; start = previous
                }
                var end = start, byteCount = 0
                while end < line.endIndex {
                    let next = line.unicodeScalars.index(after: end)
                    let count = line[end..<next].utf8.count
                    if byteCount + count > 512 { break }
                    byteCount += count; end = next
                }
                try add(["path": path, "line": index + 1, "text": String(line[start..<end]),
                         "snippetTruncated": start != line.startIndex || end != line.endIndex, "sha256": hash])
            }
        }

        func add(_ value: [String: Any]) throws {
            matchesSeen += 1
            if matchesSeen <= request.offset { return }
            if matches.count == request.limit {
                stopReason = request.offset + matches.count > 1000 ? "offsetLimit" : "resultLimit"
                return
            }
            matches.append(value)
            // Reserve the worst-case small metadata growth after discovering the
            // next match. Never rely on the runtime's plain-text truncation.
            if try encoded().count > limits.outputBytes - 512 {
                matches.removeLast()
                stopReason = request.offset + matches.count > 1000 ? "offsetLimit" : "outputLimit"
            }
        }

        func encoded() throws -> Data {
            let more = stopReason == "resultLimit" || stopReason == "outputLimit"
            let next = request.offset + matches.count
            let nextOffset: Any = more && !matches.isEmpty && next <= 1000 ? next : NSNull()
            var result: [String: Any] = [
                "kind": request.query == nil ? "files" : "content", "path": request.path,
                "nameGlob": request.nameGlob, "includeHidden": request.includeHidden,
                "offset": request.offset, "limit": request.limit, "matches": matches,
                "nextOffset": nextOffset, "truncated": stopReason != nil, "stopReason": stopReason as Any? ?? NSNull(),
                "stats": ["entriesVisited": entriesVisited, "filesRead": filesRead, "bytesRead": bytesRead, "matchesSeen": matchesSeen],
                "skipped": skipped,
                "exclusions": ["directories": WorkspaceSearch.excludedDirectories.sorted(), "hidden": !request.includeHidden,
                               "gitignoreApplied": false],
                "limits": ["entries": limits.entries, "files": limits.files, "readBytes": limits.readBytes,
                           "fileBytes": limits.fileBytes, "depth": limits.depth, "seconds": limits.seconds,
                           "outputBytes": limits.outputBytes, "maxOffset": 1000],
            ]
            if let query = request.query { result["query"] = query; result["caseSensitive"] = request.caseSensitive }
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }
}
