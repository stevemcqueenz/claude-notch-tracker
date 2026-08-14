import Foundation

/// Where Antigravity keeps its data, and where its CLI lives.
enum AntigravityPaths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Antigravity's app-data roots, newest layout first. The CLI and the IDE keep separate
    /// stores under the same parent, and a machine may well have both.
    static var dataDirectories: [URL] {
        let gemini = home.appendingPathComponent(".gemini")
        return [
            gemini.appendingPathComponent("antigravity-cli"),
            gemini.appendingPathComponent("antigravity"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every per-conversation store, across all roots.
    static func conversationStores() -> [URL] {
        dataDirectories.flatMap { root -> [URL] in
            let directory = root.appendingPathComponent("conversations")
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            return (contents ?? []).filter { $0.pathExtension == "db" }
        }
    }

    /// The model the user has selected, as the CLI writes it in settings.json
    /// (e.g. "Gemini 3.7 Flash (High)"). Read from disk rather than asked of the CLI, so the
    /// active-model tile costs no subprocess.
    static func activeModel() -> String? {
        for root in dataDirectories {
            let url = root.appendingPathComponent("settings.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = object["model"] as? String,
                  !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    /// The `agy` executable, in the order a machine is most likely to have a trustworthy copy.
    ///
    /// Only ever launched with fixed arguments and never through a shell — and as with
    /// `CODEX_NOTCH_BINARY`, the environment override must only be pointed at a trusted binary.
    static func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["ANTIGRAVITY_NOTCH_BINARY"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/agy" }
        }
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }
}
