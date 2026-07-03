import AppKit

@MainActor @Observable
final class AppMonitor {
    var claudeRunning = false
    /// Notch metrics for the main screen. width==0 => no notch (use pill fallback).
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 0

    private let claudeBundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        updateNotch()
        updateClaude()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateClaude() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateNotch(); self?.onChange?() }
        }
    }

    private func updateClaude() {
        // Exact bundle-id match only — a loose contains("claude") would
        // false-positive on other apps (e.g. third-party usage trackers).
        let running = NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier else { return false }
            return claudeBundleIDs.contains(id)
        }
        if running != claudeRunning { claudeRunning = running; onChange?() }
    }

    private func updateNotch() {
        guard let screen = NSScreen.main else { return }
        notchHeight = screen.safeAreaInsets.top
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        } else {
            notchWidth = 0
        }
    }
}
