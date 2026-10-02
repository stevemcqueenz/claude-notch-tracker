import Foundation

/// Where opencode-go keeps its credentials and local history.
///
/// Detection here is deliberately cheap and side-effect free: file existence (and one JSON read
/// of the small auth file) only, exactly like the other providers. Nothing is launched and no
/// network call is made, so this is safe to ask from the constantly re-rendering pill.
enum OpencodeGoPaths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var directory: URL {
        home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// opencode stores gateway credentials per provider; opencode-go's key lives under this key.
    static var authURL: URL { directory.appendingPathComponent("auth.json", isDirectory: false) }
    static var databaseURL: URL { directory.appendingPathComponent("opencode.db", isDirectory: false) }

    /// True when auth.json carries a non-empty `opencode-go.key`.
    static var hasAuth: Bool {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }
}
