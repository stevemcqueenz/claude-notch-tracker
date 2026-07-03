import Foundation

/// Parses log files off the main actor. UsageEvent is Sendable, so the
/// returned tuples cross back to the caller's actor safely.
actor LogLoader {
    func parse(_ files: [URL]) -> [(url: URL, events: [UsageEvent])] {
        files.compactMap { url in
            guard let events = try? LogParser.parse(fileURL: url) else { return nil }
            return (url, events)
        }
    }
}
