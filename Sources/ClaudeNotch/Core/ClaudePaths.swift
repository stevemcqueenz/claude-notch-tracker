import Foundation

enum ClaudePaths {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func allLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: projectsDir,
            includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Log files modified within the last `days` days (cheap stat, no parse).
    /// Falls back to all files if none are recent.
    static func recentLogFiles(within days: Int) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let all = allLogFiles()
        let recent = all.filter { url in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return (d ?? .distantPast) >= cutoff
        }
        return recent.isEmpty ? all : recent
    }
}
