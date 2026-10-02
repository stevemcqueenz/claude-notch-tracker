import Foundation
import Testing
@testable import ClaudeNotch

/// The overview page renders `UsageProviderID.allCases` directly, so its order and the metadata
/// each row shows are the contract.
@Suite struct ProviderOverviewTests {
    @Test func includesEveryProvider() {
        #expect(UsageProviderID.allCases.count == 4)
    }

    @Test func keepsMenuOrder() {
        #expect(UsageProviderID.allCases == [.claude, .codex, .antigravity, .opencodeGo])
    }

    @Test func everyProviderCanExplainItself() {
        // A provider that isn't installed shows this instead of a raw "executable not found".
        for provider in UsageProviderID.allCases {
            #expect(!provider.displayName.isEmpty)
            #expect(!provider.setupHint.isEmpty)
            #expect(!provider.systemImage.isEmpty)
        }
    }

    @Test func opencodeGoNamesAndHint() {
        #expect(UsageProviderID.opencodeGo.displayName == "opencode-go")
        #expect(UsageProviderID.opencodeGo.setupHint == "Sign in to opencode-go to see usage here")
    }
}
