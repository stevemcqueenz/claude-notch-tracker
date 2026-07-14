import Foundation

/// Parses log files off the main actor. Results are Sendable, so they cross back to the caller's
/// actor safely.
actor LogLoader {
    struct Result: Sendable {
        let url: URL
        let events: [UsageEvent]
        let titles: [String: String]
        let newOffset: UInt64
        let reset: Bool
    }

    /// Tail-parse each file from its last-known byte offset (0 = never read). Only the newly
    /// appended bytes are read, so re-scanning a growing multi-hundred-MB log stays cheap.
    func parse(_ requests: [(url: URL, offset: UInt64)]) -> [Result] {
        requests.map { req in
            let inc = LogParser.parseIncremental(fileURL: req.url, from: req.offset)
            return Result(url: req.url, events: inc.events, titles: inc.titles,
                          newOffset: inc.newOffset, reset: inc.reset)
        }
    }
}
