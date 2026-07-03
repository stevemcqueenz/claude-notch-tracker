import Foundation
import Security
import CommonCrypto
import SQLite3

/// Live account limits fetched from claude.ai (same source Claude Desktop uses).
struct ClaudeLimits: Sendable {
    var sessionPct: Double?      // 0…1 used (five_hour)
    var sessionResetsAt: Date?
    var weeklyPct: Double?       // 0…1 used (seven_day)
    var weeklyResetsAt: Date?
    var fetchedAt: Date
}

/// Reads Claude Desktop's local session (Chromium cookie store, decrypted with the
/// "Claude Safe Storage" Keychain key) and queries claude.ai for the real usage.
/// An actor so the blocking Keychain / SQLite / crypto work stays off the main thread.
actor ClaudeAPIService {

    func fetch() async -> ClaudeLimits? {
        guard let cookies = readCookies(),
              let org = cookies["lastActiveOrg"], cookies["sessionKey"] != nil,
              let url = URL(string: "https://claude.ai/api/organizations/\(org)/usage")
        else { return nil }

        let header = cookies.map { "\($0)=\($1)" }.joined(separator: "; ")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                     forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(obj)
    }

    private func parse(_ obj: [String: Any]) -> ClaudeLimits {
        func node(_ key: String) -> (Double?, Date?) {
            guard let n = obj[key] as? [String: Any] else { return (nil, nil) }
            let util = (n["utilization"] as? NSNumber)?.doubleValue
            let resetStr = (n["resets_at"] as? String) ?? (n["resetsAt"] as? String)
            let reset = resetStr.flatMap { s -> Date? in
                let f1 = ISO8601DateFormatter()
                if let d = f1.date(from: s) { return d }
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f2.date(from: s)
            }
            return (util.map { min(1, max(0, $0 / 100)) }, reset)
        }
        let (s, sr) = node("five_hour")
        let (w, wr) = node("seven_day")
        return ClaudeLimits(sessionPct: s, sessionResetsAt: sr,
                            weeklyPct: w, weeklyResetsAt: wr, fetchedAt: Date())
    }

    // MARK: - cookie store

    private func readCookies() -> [String: String]? {
        guard let key = safeStorageKey() else { return nil }
        let src = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-cookies-\(getpid()).sqlite")
        try? FileManager.default.removeItem(at: tmp)
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open(tmp.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: cName)
            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 1))
            let enc = Data(bytes: blob, count: len)
            if let val = decrypt(enc, key: key) { out[name] = val }
        }
        return out.isEmpty ? nil : out
    }

    /// The AES key = PBKDF2(SHA1, "Claude Safe Storage" password, "saltysalt", 1003, 16).
    private func safeStorageKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let pw = item as? Data else { return nil }

        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let ok = key.withUnsafeMutableBytes { kb in
            pw.withUnsafeBytes { pb in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pb.baseAddress!.assumingMemoryBound(to: Int8.self), pw.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    kb.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        return ok == kCCSuccess ? key : nil
    }

    /// Chromium "v10" AES-128-CBC (IV = 16 × 0x20). Newer builds prepend a 32-byte
    /// domain hash inside the plaintext; try with and without.
    private func decrypt(_ enc: Data, key: Data) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else {
            return String(data: enc, encoding: .utf8)   // unencrypted cookie
        }
        let ct = enc.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: ct.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { ob in
            ct.withUnsafeBytes { cb in key.withUnsafeBytes { kb in iv.withUnsafeBytes { ib in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, 16, ib.baseAddress,
                        cb.baseAddress, ct.count,
                        ob.baseAddress, ob.count, &moved)
            }}}
        }
        guard status == kCCSuccess else { return nil }
        let total = out.count
        out.removeSubrange(moved..<total)
        if let s = String(data: out, encoding: .utf8) { return s }
        if out.count > 32, let s = String(data: out.dropFirst(32), encoding: .utf8) { return s }
        return nil
    }
}
