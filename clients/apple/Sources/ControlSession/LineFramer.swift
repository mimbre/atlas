import Foundation

/// Frames a byte stream into lines: each complete line without its newline (and without a
/// carriage return before it). A line longer than `limit` bytes is an error, as the TUI's
/// socket buffer (4 MB) is its limit; the connection that gets one closes.
public struct LineFramer: Sendable {
    public static let defaultLimit = 4 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case tooLong
    }

    public let limit: Int
    private var buffer = Data()

    public init(limit: Int = LineFramer.defaultLimit) {
        self.limit = limit
    }

    /// The lines `bytes` completes, in order; what follows the last newline waits for more.
    public mutating func append(_ bytes: Data) throws(Failure) -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var end = newline
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            guard end - start <= limit else { throw .tooLong }
            lines.append(Data(buffer[start..<end]))
            start = newline + 1
        }
        buffer = Data(buffer[start...])
        guard buffer.count <= limit else { throw .tooLong }
        return lines
    }
}
