import Testing
@testable import ClaudeNotch

/// Fixture tests for the pure payload walk behind hide-in-fullscreen. The payload shapes mirror
/// live `CGSCopyManagedDisplaySpaces` output (validated on macOS 27 on a notched MacBook Pro);
/// since the API is private, these pin the parsing so a behavior change on a future macOS shows
/// up as a red test instead of a silently broken feature.
@Suite struct SpaceInfoTests {
    private let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    /// A display entry in the shape the WindowServer returns.
    private func display(identifier: String,
                         current: [String: Any],
                         spaces: [[String: Any]] = []) -> [String: Any] {
        ["Display Identifier": identifier, "Current Space": current, "Spaces": spaces]
    }

    // MARK: inline `type` on "Current Space" (the shape seen live on macOS 27)

    @Test func inlineFullscreenTypeHides() {
        let d = display(identifier: uuid,
                        current: ["ManagedSpaceID": 5, "id64": 5, "type": 4, "uuid": "S-5"])
        #expect(SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: true))
    }

    @Test func inlineDesktopTypeDoesNotHide() {
        let d = display(identifier: uuid,
                        current: ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": "S-1"])
        #expect(!SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: true))
    }

    // MARK: `type` resolved through the "Spaces" list (identity-only "Current Space")

    @Test func resolvesTypeThroughSpacesByManagedSpaceID() {
        let d = display(identifier: uuid,
                        current: ["ManagedSpaceID": 7],
                        spaces: [["ManagedSpaceID": 1, "type": 0],
                                 ["ManagedSpaceID": 7, "type": 4]])
        #expect(SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: true))
    }

    @Test func resolvesTypeThroughSpacesByUUID() {
        let d = display(identifier: uuid,
                        current: ["uuid": "S-9"],
                        spaces: [["uuid": "S-1", "type": 0],
                                 ["uuid": "S-9", "type": 4]])
        #expect(SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: true))
    }

    @Test func unresolvableCurrentSpaceFailsSafe() {
        let d = display(identifier: uuid,
                        current: ["ManagedSpaceID": 99],   // no matching entry in Spaces
                        spaces: [["ManagedSpaceID": 1, "type": 4]])
        #expect(!SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: true))
    }

    // MARK: display matching and fallbacks

    @Test func mainEntryFallbackAppliesOnlyToMainDisplay() {
        let d = display(identifier: "Main", current: ["type": 4])
        let other = display(identifier: "B", current: ["type": 0])
        #expect(SpaceInfo.isFullscreen(displays: [d, other], wantUUID: uuid, isMainDisplay: true))
        #expect(!SpaceInfo.isFullscreen(displays: [d, other], wantUUID: uuid, isMainDisplay: false))
    }

    @Test func soleEntryFallbackWhenSeparateSpacesOff() {
        // "Displays have separate Spaces" off: one combined entry whose identifier matches nothing.
        let d = display(identifier: "Combined", current: ["type": 4])
        #expect(SpaceInfo.isFullscreen(displays: [d], wantUUID: uuid, isMainDisplay: false))
    }

    @Test func multipleEntriesWithNoMatchFailSafe() {
        let a = display(identifier: "A", current: ["type": 4])
        let b = display(identifier: "B", current: ["type": 4])
        #expect(!SpaceInfo.isFullscreen(displays: [a, b], wantUUID: uuid, isMainDisplay: false))
    }

    @Test func nilWantUUIDNeverMatchesArbitraryEntry() {
        // A nil display UUID must not accidentally select some entry via nil == nil comparison.
        let a = display(identifier: "A", current: ["type": 4])
        let b = display(identifier: "B", current: ["type": 4])
        #expect(!SpaceInfo.isFullscreen(displays: [a, b], wantUUID: nil, isMainDisplay: false))
    }

    // MARK: junk payloads

    @Test func junkPayloadsFailSafe() {
        #expect(!SpaceInfo.isFullscreen(displays: [], wantUUID: uuid, isMainDisplay: true))
        #expect(!SpaceInfo.isFullscreen(displays: [["Display Identifier": uuid]],   // no Current Space
                                        wantUUID: uuid, isMainDisplay: true))
        let typeless = display(identifier: uuid, current: ["wsid": 3])              // no type anywhere
        #expect(!SpaceInfo.isFullscreen(displays: [typeless], wantUUID: uuid, isMainDisplay: true))
    }
}
