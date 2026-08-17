import Foundation

/// A read-only view over a protobuf wire-format buffer, holding no schema of its own.
///
/// Antigravity stores its per-turn token counts as serialized protobuf in SQLite blobs, and ships
/// no `.proto` for them. Rather than vendor a full protobuf runtime for six integers, this walks
/// the wire format directly and returns only the fields asked for. Unknown fields are skipped by
/// their wire type, so an added or reordered field in a future release is ignored rather than
/// misread.
///
/// Every accessor returns nil on a truncated or malformed buffer; callers treat that as "no data"
/// rather than surfacing a parse error, because a single unreadable row must not fail a scan.
struct ProtobufMessage {
    private let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    private init(bytes: [UInt8]) { self.bytes = bytes }

    /// The first varint (wire type 0) carried by `field`.
    func varint(_ field: Int) -> UInt64? {
        guard case .varint(let value)? = first(field) else { return nil }
        return value
    }

    /// The first length-delimited (wire type 2) payload of `field`, read as a nested message.
    func message(_ field: Int) -> ProtobufMessage? {
        guard case .bytes(let payload)? = first(field) else { return nil }
        return ProtobufMessage(bytes: payload)
    }

    /// The first length-delimited payload of `field`, read as UTF-8.
    func string(_ field: Int) -> String? {
        guard case .bytes(let payload)? = first(field) else { return nil }
        return String(bytes: payload, encoding: .utf8)
    }

    private enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    private func first(_ field: Int) -> Value? {
        var index = 0
        while index < bytes.count {
            guard let (key, afterKey) = varint(at: index) else { return nil }
            index = afterKey
            let number = Int(key >> 3)
            switch key & 0b111 {
            case 0:
                guard let (value, afterValue) = varint(at: index) else { return nil }
                index = afterValue
                if number == field { return .varint(value) }
            case 1:
                index += 8
                guard index <= bytes.count else { return nil }
            case 2:
                guard let (length, afterLength) = varint(at: index),
                      length <= UInt64(bytes.count) else { return nil }
                let start = afterLength
                let end = start + Int(length)
                guard end <= bytes.count else { return nil }
                index = end
                if number == field { return .bytes(Array(bytes[start..<end])) }
            case 5:
                index += 4
                guard index <= bytes.count else { return nil }
            default:
                // Groups (3/4) are deprecated and absent here; stop rather than guess a length.
                return nil
            }
        }
        return nil
    }

    private func varint(at index: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = index
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, cursor) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
