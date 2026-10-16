import Foundation
import LatheLocalization

/// Incremental SSE framing. UTF-8 is decoded only after a complete line, so a
/// multibyte scalar may be split across any number of transport chunks.
struct SSEDecoder {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousCR = false
    private var firstLine = true
    static let frameLimit = 1024 * 1024

    mutating func feed(_ bytes: Data) throws -> [String] {
        var events: [String] = []
        for byte in bytes {
            if previousCR {
                previousCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                previousCR = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= Self.frameLimit else { throw ProviderError.responseLimit }
            }
        }
        return events
    }

    private mutating func consumeLine() throws -> String? {
        guard var text = String(data: line, encoding: .utf8) else { throw ProviderError.invalidStream(L10n.errorText("provider.stream.invalidUTF8", table: "ProviderErrors")) }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.first == "\u{feff}" { text.removeFirst() } }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        if text.first == ":" { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return nil }
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        eventBytes += value.utf8.count + 1
        guard eventBytes <= Self.frameLimit else { throw ProviderError.responseLimit }
        dataLines.append(value)
        return nil
    }
}
