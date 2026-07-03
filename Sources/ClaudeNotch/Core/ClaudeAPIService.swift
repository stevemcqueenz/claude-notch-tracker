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
    var creditsPct: Double?      // 0…1 used (extra_usage), nil if no credits
    var source: String?          // where the session came from (e.g. "Brave")
    var fetchedAt: Date
}

/// Finds a logged-in claude.ai session — from Claude Desktop OR any supported browser — and
/// queries claude.ai for the real usage. An actor so the blocking Keychain / SQLite / crypto
/// work stays off the main thread.
actor ClaudeAPIService {

    private struct Source {
        let name: String
        let path: URL
        let keychainService: String?   // nil => Firefox-style plaintext cookies.sqlite
    }

    func fetch() async -> ClaudeLimits? {
        for source in sources() {
            guard let cookies = readCookies(from: source),
                  let org = cookies["lastActiveOrg"], cookies["sessionKey"] != nil
            else { continue }
            if let limits = await request(org: org, cookies: cookies, source: source.name) {
                return limits
            }
        }
        return nil
    }

    /// Candidate session stores, most-likely first. Only those actually present are returned.
    private func sources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        func url(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        var out: [Source] = []

        let chromium: [(String, String, String)] = [
            ("Claude Desktop", "Library/Application Support/Claude/Cookies", "Claude Safe Storage"),
            ("Chrome", "Library/Application Support/Google/Chrome/Default/Cookies", "Chrome Safe Storage"),
            ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies", "Brave Safe Storage"),
            ("Edge", "Library/Application Support/Microsoft Edge/Default/Cookies", "Microsoft Edge Safe Storage"),
            ("Arc", "Library/Application Support/Arc/User Data/Default/Cookies", "Arc Safe Storage"),
        ]
        for (name, rel, svc) in chromium {
            let u = url(rel)
            if fm.fileExists(atPath: u.path) { out.append(Source(name: name, path: u, keychainService: svc)) }
        }

        for (name, base) in [("Firefox", "Library/Application Support/Firefox/Profiles"),
                             ("Zen", "Library/Application Support/zen/Profiles")] {
            let dir = url(base)
            if let profiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for prof in profiles {
                    let ck = prof.appendingPathComponent("cookies.sqlite")
                    if fm.fileExists(atPath: ck.path) {
                        out.append(Source(name: name, path: ck, keychainService: nil))
                    }
                }
            }
        }
        return out
    }

    private func request(org: String, cookies: [String: String], source: String) async -> ClaudeLimits? {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(org)/usage") else { return nil }
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
        return parse(obj, source: source)
    }

    private func parse(_ obj: [String: Any], source: String) -> ClaudeLimits {
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
        let (c, _) = node("extra_usage")
        return ClaudeLimits(sessionPct: s, sessionResetsAt: sr,
                            weeklyPct: w, weeklyResetsAt: wr,
                            creditsPct: c, source: source, fetchedAt: Date())
    }

    // MARK: - cookie stores

    private func readCookies(from source: Source) -> [String: String]? {
        guard let db = openCopy(of: source.path) else { return nil }
        defer { sqlite3_close(db); }
        if let service = source.keychainService {
            return readChromium(db, service: service)
        } else {
            return readFirefox(db)
        }
    }

    /// Copy the (possibly locked) SQLite file to temp and open it read-only.
    private func openCopy(of path: URL) -> OpaquePointer? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-\(abs(path.hashValue))-\(getpid()).sqlite")
        try? FileManager.default.removeItem(at: tmp)
        guard (try? FileManager.default.copyItem(at: path, to: tmp)) != nil else { return nil }
        var db: OpaquePointer?
        let ok = sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        try? FileManager.default.removeItem(at: tmp)   // opened handle keeps the data
        return ok ? db : nil
    }

    private func readChromium(_ db: OpaquePointer, service: String) -> [String: String]? {
        guard let key = safeStorageKey(service: service) else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1)
            else { continue }
            let name = String(cString: cName)
            let enc = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
            if let val = decrypt(enc, key: key) { out[name] = val }
        }
        return out.isEmpty ? nil : out
    }

    private func readFirefox(_ db: OpaquePointer) -> [String: String]? {
        var stmt: OpaquePointer?
        let sql = "SELECT name, value FROM moz_cookies WHERE host LIKE '%claude.ai%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0), let cVal = sqlite3_column_text(stmt, 1)
            else { continue }
            out[String(cString: cName)] = String(cString: cVal)   // Firefox stores plaintext
        }
        return out.isEmpty ? nil : out
    }

    /// AES key = PBKDF2(SHA1, "<App> Safe Storage" password, "saltysalt", 1003, 16).
    private func safeStorageKey(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
            return String(data: enc, encoding: .utf8)
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
