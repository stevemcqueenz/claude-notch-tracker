import Foundation

/// Watches ~/.claude/projects recursively and reports changed .jsonl paths.
final class LogWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor ([URL]) -> Void
    private var pending = Set<URL>()
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping @MainActor ([URL]) -> Void) { self.onChange = onChange }

    func start() {
        let path = ClaudePaths.projectsDir.path as CFString
        var ctx = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)   // so eventPaths is a CFArray
        guard let s = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            watcher.handle(cPaths)
        }, &ctx, [path] as CFArray,
           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(_ paths: [String]) {
        let urls = paths.filter { $0.hasSuffix(".jsonl") }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        pending.formUnion(urls)
        let callback = onChange
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending); self.pending.removeAll()
            Task { @MainActor in callback(batch) }
        }
        debounce?.cancel(); debounce = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
