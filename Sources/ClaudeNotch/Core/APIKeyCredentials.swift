import Foundation

/// An API key for a provider that has nothing else to sign in with: the provider's environment
/// variable when the app was launched with one, else a generic-password item this app writes to
/// the login Keychain from the right-click menu (see APIKeyKeychain.swift). Each key is only ever
/// sent to its own provider.
struct APIKeyCredentials: Sendable {
    let service: String
    let account: String
    let environmentVariable: String
    /// Lets availability be answered without touching the Keychain, which `ProviderAvailability`
    /// promises never to do.
    let storedFlag: String

    // These strings name items already in users' Keychains and defaults: changing one loses
    // the saved key.
    static let deepseek = APIKeyCredentials(service: "Claude Notch – DeepSeek API key",
                                            account: "api-key",
                                            environmentVariable: "DEEPSEEK_API_KEY",
                                            storedFlag: "deepseekKeyStored")
    static let ollama = APIKeyCredentials(service: "Claude Notch – Ollama API key",
                                          account: "api-key",
                                          environmentVariable: "OLLAMA_API_KEY",
                                          storedFlag: "ollamaKeyStored")

    var environmentKey: String? {
        let key = ProcessInfo.processInfo.environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    var isConfigured: Bool {
        environmentKey != nil || UserDefaults.standard.bool(forKey: storedFlag)
    }
}
