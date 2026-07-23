import Foundation

enum LogParser {
    private struct Line: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let requestId: String?
        let cwd: String?
        let message: Message?
    }
    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }
    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    /// The "custom-title" line carries the conversation name shown in the Claude sidebar.
    private struct TitleLine: Decodable {
        let type: String?
        let sessionId: String?
        let customTitle: String?
    }

    /// A fresh decoder per batch: parsing runs from several actors concurrently (live loader,
    /// lifetime scanner), and neither JSONDecoder nor a shared date-strategy closure is documented
    /// concurrency-safe. Costs nothing at batch granularity.
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = fmt.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                debugDescription: "bad date \(s)"))
        }
        return d
    }

    /// A parsed batch of log bytes: usage events plus any conversation titles (sessionId → name).
    struct Batch: Sendable {
        let events: [UsageEvent]
        let titles: [String: String]
    }

    /// Result of an incremental (tail) parse: the events + titles found in the newly-read bytes, the
    /// byte offset to resume from next time, and whether this was a fresh/full read (so the caller
    /// should replace the file's events rather than append).
    struct Incremental: Sendable {
        let events: [UsageEvent]
        let titles: [String: String]
        let newOffset: UInt64
        let reset: Bool
    }

    /// Full parse of a whole file (used at startup and as the truncation fallback).
    static func parse(fileURL: URL) throws -> [UsageEvent] {
        parseBatch(data: try Data(contentsOf: fileURL)).events
    }

    /// Parse only the bytes after `offset`. Reads to EOF but consumes only through the last complete
    /// line, so a line still being written is picked up on the next call. If the file shrank since
    /// last time (rotated/truncated), it restarts from 0 and flags `reset` so the caller replaces.
    static func parseIncremental(fileURL: URL, from offset: UInt64) -> Incremental {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return Incremental(events: [], titles: [:], newOffset: offset, reset: false)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start: UInt64 = offset > size ? 0 : offset   // shrank → re-read from the top
        let reset = start == 0
        guard start < size, (try? handle.seek(toOffset: start)) != nil else {
            return Incremental(events: [], titles: [:], newOffset: min(offset, size), reset: reset)
        }
        let data = handle.readDataToEndOfFile()                 // bytes [start, size)
        guard let lastNL = data.lastIndex(of: 0x0A) else {       // no complete line yet
            return Incremental(events: [], titles: [:], newOffset: start, reset: reset)
        }
        let complete = data[...lastNL]                           // through the final newline
        let batch = parseBatch(data: Data(complete))
        return Incremental(events: batch.events, titles: batch.titles,
                           newOffset: start + UInt64(complete.count), reset: reset)
    }

    static func parse(data: Data) -> [UsageEvent] { parseBatch(data: data).events }

    /// Parse newline-delimited JSON out of a Data buffer into events + titles. Malformed lines are
    /// skipped, so one bad (or partially-written) line never sinks the batch.
    static func parseBatch(data: Data) -> Batch {
        var events: [UsageEvent] = []
        var titles: [String: String] = [:]
        let titleMarker = Data("custom-title".utf8)
        let decoder = makeDecoder()
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let d = Data(raw)
            if let e = parseLine(d, decoder: decoder) { events.append(e); continue }
            // Cheap byte pre-check so we don't second-decode every non-event line.
            if d.range(of: titleMarker) != nil,
               let t = try? decoder.decode(TitleLine.self, from: d),
               t.type == "custom-title", let sid = t.sessionId, let title = t.customTitle {
                titles[sid] = title
            }
        }
        return Batch(events: events, titles: titles)
    }

    private static func parseLine(_ data: Data, decoder: JSONDecoder) -> UsageEvent? {
        guard let line = try? decoder.decode(Line.self, from: data),
              line.type == "assistant",
              let msg = line.message,
              let usage = msg.usage,
              let model = msg.model, model != "<synthetic>",
              let ts = line.timestamp,
              let sid = line.sessionId
        else { return nil }
        return UsageEvent(
            timestamp: ts,
            sessionId: sid,
            requestId: line.requestId,
            messageId: msg.id,
            model: model,
            cwd: line.cwd ?? "",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0)
    }
}
