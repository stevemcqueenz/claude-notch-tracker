import Foundation

/// Where the Codex CLI lives. Shared so provider detection and the app-server transport agree on
/// what "installed" means, rather than each keeping its own copy of the candidate list.
enum CodexPaths {
    /// The `codex` executable, most likely locations first. Cheap: file existence only, no launch.
    ///
    /// Only ever run with fixed arguments and never through a shell; as with the environment
    /// override, point `CODEX_NOTCH_BINARY` at a trusted binary only.
    static func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["CODEX_NOTCH_BINARY"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            // The Codex app was folded into ChatGPT.app, so that path comes first.
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }
}
