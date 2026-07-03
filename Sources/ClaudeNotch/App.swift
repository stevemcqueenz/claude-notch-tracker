import Foundation

@main
struct Main {
    static func main() {
        setbuf(stdout, nil)   // unbuffered so smoke-test output appears promptly
        let store = UsageStore()
        for f in ClaudePaths.allLogFiles() { try? store.ingest(fileURL: f) }
        print("initial:", store.snapshot(now: Date()))
        let watcher = LogWatcher { urls in
            for u in urls { try? store.ingest(fileURL: u) }
            print("update:", store.snapshot(now: Date()))
        }
        watcher.start()
        RunLoop.main.run()
    }
}
