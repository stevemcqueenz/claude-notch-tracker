import Foundation

/// Lightweight "is there a newer release?" check against the GitHub releases API.
enum UpdateChecker {
    static let repo = "stevemcqueenz/claude-notch-tracker"
    static let releasesURL = "https://github.com/\(repo)/releases/latest"

    /// Latest release version (e.g. "0.1.3") if it's newer than `current`, else nil.
    static func latestIfNewer(than current: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(latest, than: current) ? latest : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
