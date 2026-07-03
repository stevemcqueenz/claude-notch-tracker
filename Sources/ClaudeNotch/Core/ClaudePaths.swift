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
}
