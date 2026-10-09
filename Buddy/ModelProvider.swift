import Foundation

enum ModelProvider: String, Codable, CaseIterable {
    case claudeCLI
    case claudeAPI
    case openAI
    case gemini
    case buddyProxy

    var apiKeyService: String? {
        switch self {
        case .claudeAPI: return KeychainHelper.claudeAPIKey
        case .openAI: return KeychainHelper.openAIAPIKey
        case .gemini: return KeychainHelper.geminiAPIKey
        case .claudeCLI, .buddyProxy: return nil
        }
    }

    var requiresAPIKey: Bool { apiKeyService != nil }
}

struct ModelConfig: Codable {
    var provider: ModelProvider
    var modelId: String
    var displayName: String
    var apiKey: String?
    var isSubscription: Bool

    init(provider: ModelProvider, modelId: String, displayName: String, apiKey: String? = nil, isSubscription: Bool = false) {
        self.provider = provider
        self.modelId = modelId
        self.displayName = displayName
        self.apiKey = apiKey
        self.isSubscription = isSubscription
    }
}

struct AvailableModels {
    struct ModelInfo {
        let id: String
        let displayName: String
        let provider: ModelProvider
    }

    static let all: [ModelInfo] = [
        // Claude CLI (uses whatever model the CLI is configured with)
        ModelInfo(id: "claude-cli", displayName: "Claude CLI", provider: .claudeCLI),

        // Claude API
        ModelInfo(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", provider: .claudeAPI),
        ModelInfo(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", provider: .claudeAPI),

        // OpenAI
        ModelInfo(id: "gpt-4o", displayName: "GPT-4o", provider: .openAI),
        ModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openAI),
        ModelInfo(id: "gpt-4.1", displayName: "GPT-4.1", provider: .openAI),
        ModelInfo(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: .openAI),

        // Gemini
        ModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini),
        ModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini),
    ]

    static func models(for provider: ModelProvider) -> [ModelInfo] {
        // Use the Claude catalog for the Claude-style proxy.
        if provider == .buddyProxy {
            return all.filter { $0.provider == .claudeAPI }.map {
                ModelInfo(id: $0.id, displayName: $0.displayName, provider: .buddyProxy)
            }
        }
        return all.filter { $0.provider == provider }
    }

    static func defaultModel(for provider: ModelProvider) -> ModelInfo? {
        models(for: provider).first
    }
}
