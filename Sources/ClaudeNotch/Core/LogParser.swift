import Foundation

enum LogParser {
    private struct Line: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let requestId: String?
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

    static let decoder: JSONDecoder = {
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
    }()

    static func parse(fileURL: URL) throws -> [UsageEvent] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var out: [UsageEvent] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let line = try? decoder.decode(Line.self, from: data)
            else { continue }
            guard line.type == "assistant",
                  let msg = line.message,
                  let usage = msg.usage,
                  let model = msg.model, model != "<synthetic>",
                  let ts = line.timestamp,
                  let sid = line.sessionId
            else { continue }
            out.append(UsageEvent(
                timestamp: ts,
                sessionId: sid,
                requestId: line.requestId,
                messageId: msg.id,
                model: model,
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
                cacheReadTokens: usage.cache_read_input_tokens ?? 0))
        }
        return out
    }
}
