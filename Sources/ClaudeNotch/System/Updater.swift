import Foundation
import Sparkle

/// Wraps Sparkle's updater. Auto-checks per Info.plist (SUEnableAutomaticChecks); the menu's
/// "Check for Updates…" calls `checkForUpdates()`. No-ops in the raw dev binary (Sparkle needs
/// a real bundle with SUFeedURL / SUPublicEDKey).
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?

    private init() {
        controller = Bundle.main.bundleIdentifier != nil
            ? SPUStandardUpdaterController(startingUpdater: true,
                                           updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Force initialization (starts the background updater).
    func start() { _ = controller }

    func checkForUpdates() { controller?.updater.checkForUpdates() }
}
