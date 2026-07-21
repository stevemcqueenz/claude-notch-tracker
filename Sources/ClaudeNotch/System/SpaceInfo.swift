import AppKit

// Private SkyLight (WindowServer) Spaces API. These symbols live in SkyLight.framework, which is
// already loaded via AppKit/CoreGraphics at runtime, so the dynamic linker resolves them. Reading a
// Space's type needs no Accessibility or Screen Recording permission.
private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

// Follows the CF Copy rule (+1), and can return NULL when no WindowServer connection is available
// (e.g. our session is inactive during fast user switching) — so take it as an optional Unmanaged
// and retain explicitly instead of letting Swift assume a valid owned reference.
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

/// Space types reported by the WindowServer. A macOS-native fullscreen window lives on its own
/// Space whose type is `fullscreen`; ordinary desktops are `user`.
private let kCGSSpaceFullscreen = 4

enum SpaceInfo {
    /// True when the Space currently active on `screen` is a fullscreen Space.
    ///
    /// This asks the WindowServer directly instead of guessing from window bounds, so it can't be
    /// fooled by a maximized/zoomed window and doesn't depend on notch geometry. Refreshed by the
    /// caller on `activeSpaceDidChangeNotification`.
    static func fullscreenSpaceActive(on screen: NSScreen) -> Bool {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        let displayID = CGDirectDisplayID(num.uint32Value)
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]]
        else { return false }
        return isFullscreen(displays: displays,
                            wantUUID: displayUUID(displayID),
                            isMainDisplay: displayID == CGMainDisplayID())
    }

    /// Pure payload walk, separated from the WindowServer call so fixture tests can exercise every
    /// shape the private API is known to return. Fails safe to `false` on anything unexpected, so a
    /// changed payload on a future macOS degrades to "island stays visible", never a wrong hide.
    static func isFullscreen(displays: [[String: Any]], wantUUID: String?, isMainDisplay: Bool) -> Bool {
        // Match the island's display by UUID; fall back to the "Main" entry, or the sole entry when
        // "Displays have separate Spaces" is off (one combined entry covers everything).
        let byUUID = wantUUID.flatMap { uuid in
            displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        let match = byUUID
            ?? (isMainDisplay ? displays.first { ($0["Display Identifier"] as? String) == "Main" } : nil)
            ?? (displays.count == 1 ? displays.first : nil)

        guard let display = match,
              let current = display["Current Space"] as? [String: Any] else { return false }

        // Some macOS builds inline `type` on "Current Space"; honor that first.
        if let type = current["type"] as? Int { return type == kCGSSpaceFullscreen }

        // Otherwise "Current Space" carries only the space's identity (ManagedSpaceID / uuid); the
        // `type` lives on the matching entry in "Spaces". Resolve it there.
        let currentID = current["ManagedSpaceID"] as? Int ?? current["id64"] as? Int
        let currentUUID = current["uuid"] as? String
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let space = spaces.first {
            (currentID != nil && ($0["ManagedSpaceID"] as? Int ?? $0["id64"] as? Int) == currentID)
                || (currentUUID != nil && ($0["uuid"] as? String) == currentUUID)
        }
        guard let type = space?["type"] as? Int else { return false }
        return type == kCGSSpaceFullscreen
    }

    private static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
