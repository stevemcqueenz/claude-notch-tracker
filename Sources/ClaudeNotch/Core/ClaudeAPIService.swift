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
    var creditsPct: Double?      // 0…1 of the monthly extra-usage spend cap used, nil if unknown
    var creditsBalanceMinor: Int?    // purchased usage-credit balance in minor units (e.g. 4251)
    var creditsCurrency: String?     // ISO code for the balance, e.g. "EUR"
    var fablePct: Double?        // 0…1 used (Fable's own weekly limit), nil if absent
    var fableResetsAt: Date?
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
        // Terminal-only fallback: the Claude Code CLI's own OAuth token, so users with neither
        // Claude Desktop nor a logged-in browser still get real numbers.
        return await fetchFromCLIToken()
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
        var limits = parse(obj, source: source)
        if let (minor, currency) = await prepaidBalance(org: org, cookieHeader: header) {
            limits.creditsBalanceMinor = minor
            limits.creditsCurrency = currency
        }
        return limits
    }

    /// Purchased usage-credit balance — the "Current balance" figure on claude.ai's Usage credits
    /// settings page. Lives on its own endpoint, not in /usage (whose `spend.balance` stays null);
    /// returns e.g. {"amount": 4251, "currency": "EUR"}. Fails soft to nil, never blocks limits.
    private func prepaidBalance(org: String, cookieHeader: String) async -> (Int, String)? {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(org)/prepaid/credits")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let amount = (obj["amount"] as? NSNumber)?.intValue
        else { return nil }
        return (amount, (obj["currency"] as? String) ?? "EUR")
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
        var (w, wr) = node("seven_day")
        if w == nil {   // /api/oauth/usage splits the 7-day limit by model
            let (wo, wor) = node("seven_day_opus")
            let (ws, wsr) = node("seven_day_sonnet")
            w = [wo, ws].compactMap { $0 }.max()
            wr = wor ?? wsr
        }
        // Extra-usage consumption: `extra_usage.utilization` is null until something is spent, but
        // the newer `spend` block always carries `percent` when the feature is enabled — prefer
        // whichever is present so an enabled-but-unused month reads 0%, not "none".
        var (c, _) = node("extra_usage")
        if c == nil, let spend = obj["spend"] as? [String: Any],
           (spend["enabled"] as? Bool) == true,
           let p = (spend["percent"] as? NSNumber)?.doubleValue {
            c = min(1, max(0, p / 100))
        }

        // Fable has its own weekly limit (the Desktop app shows it) — a "weekly_scoped" entry in the
        // `limits` array whose scope.model.display_name is "Fable"; its figure is `percent` (0–100).
        var f: Double?
        var fr: Date?
        if let arr = obj["limits"] as? [[String: Any]] {
            for e in arr {
                let model = (e["scope"] as? [String: Any])?["model"] as? [String: Any]
                guard (model?["display_name"] as? String) == "Fable" else { continue }
                if let p = (e["percent"] as? NSNumber)?.doubleValue { f = min(1, max(0, p / 100)) }
                if let rs = e["resets_at"] as? String {
                    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    fr = iso.date(from: rs) ?? ISO8601DateFormatter().date(from: rs)
                }
                break
            }
        }

        return ClaudeLimits(sessionPct: s, sessionResetsAt: sr,
                            weeklyPct: w, weeklyResetsAt: wr,
                            creditsPct: c, fablePct: f, fableResetsAt: fr,
                            source: source, fetchedAt: Date())
    }

    // MARK: - Claude Code CLI (OAuth token in the Keychain)

    /// Fetch usage with the Claude Code CLI's own OAuth token — the same call the CLI makes for
    /// `/usage`. Read-only: we use the token only while it is still valid and never refresh it, so
    /// the CLI's own login is never disturbed (an expired token just falls through to nil).
    private func fetchFromCLIToken() async -> ClaudeLimits? {
        guard let (token, expiresAt) = cliOAuthToken(), expiresAt > Date(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(obj, source: "Claude Code")
    }

    /// The Claude Code CLI stores its OAuth credentials as JSON in the login Keychain under the
    /// service "Claude Code-credentials". Returns the access token and its expiry, if present.
    private func cliOAuthToken() -> (token: String, expiresAt: Date)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        // expiresAt is epoch milliseconds; a missing value reads as already-expired (→ ignored).
        let expMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return (token, Date(timeIntervalSince1970: expMs / 1000))
    }

    // MARK: - cookie stores

    private func readCookies(from source: Source) -> [String: String]? {
        let fm = FileManager.default
        let suffixes = ["", "-wal", "-shm"]
        let base = fm.temporaryDirectory
            .appendingPathComponent("cn-\(abs(source.path.path.hashValue))-\(getpid()).sqlite")
        // Copy the main DB *and* its WAL/SHM sidecars, so cookies written by a currently-running
        // app/browser (which live in the -wal file until checkpoint) are included.
        var copiedMain = false
        for s in suffixes {
            let from = URL(fileURLWithPath: source.path.path + s)
            let to = URL(fileURLWithPath: base.path + s)
            try? fm.removeItem(at: to)
            if (try? fm.copyItem(at: from, to: to)) != nil, s.isEmpty { copiedMain = true }
        }
        guard copiedMain else { return nil }
        defer { for s in suffixes { try? fm.removeItem(at: URL(fileURLWithPath: base.path + s)) } }

        // Read-WRITE open on the *copy* lets SQLite apply the WAL, so we see the latest cookies.
        var db: OpaquePointer?
        guard sqlite3_open(base.path, &db) == SQLITE_OK, let handle = db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(handle) }
        if let service = source.keychainService {
            return readChromium(handle, service: service)
        } else {
            return readFirefox(handle)
        }
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
