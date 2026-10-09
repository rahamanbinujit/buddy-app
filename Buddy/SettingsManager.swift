import Foundation

class SettingsManager {
    static let shared = SettingsManager()
    static let modelConfigChanged = Notification.Name("BuddyModelConfigChanged")

    struct Settings: Codable {
        var activeProvider: ModelProvider = .claudeCLI
        var activeModelId: String = "claude-cli"
        var preferredModels: [String: String] = [:]  // provider rawValue -> modelId
    }

    private(set) var settings = Settings()
    private let queue = DispatchQueue(label: "com.buddy.settings")
    private let settingsURL: URL

    var activeModelConfig: ModelConfig {
        let provider = settings.activeProvider
        let modelId = settings.activeModelId

        let displayName = AvailableModels.all
            .first(where: { $0.id == modelId })?.displayName ?? modelId

        let apiKey = KeychainHelper.apiKey(for: provider)

        return ModelConfig(
            provider: provider,
            modelId: modelId,
            displayName: displayName,
            apiKey: apiKey,
            isSubscription: provider == .buddyProxy
        )
    }

    init(settingsURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let buddyDir = home.appendingPathComponent(".buddy")
        self.settingsURL = settingsURL ?? buddyDir.appendingPathComponent("settings.json")

        queue.sync {
            ensureDirectory(self.settingsURL.deletingLastPathComponent())
            loadFromDisk()
        }
    }

    func save() {
        queue.sync { saveToDisk() }
    }

    func update(_ block: (inout Settings) -> Void) {
        queue.sync {
            block(&settings)
            saveToDisk()
        }
    }

    func setProvider(_ provider: ModelProvider) {
        let previous = settings
        update { s in
            s.activeProvider = provider
            // Restore preferred model for this provider, or use default
            if let preferred = s.preferredModels[provider.rawValue],
               AvailableModels.models(for: provider).contains(where: { $0.id == preferred }) {
                s.activeModelId = preferred
            } else if let defaultModel = AvailableModels.defaultModel(for: provider) {
                s.activeModelId = defaultModel.id
            }
        }
        if previous.activeProvider != settings.activeProvider || previous.activeModelId != settings.activeModelId {
            NotificationCenter.default.post(name: Self.modelConfigChanged, object: nil)
        }
    }

    func setModel(_ modelId: String) {
        guard modelId != settings.activeModelId,
              AvailableModels.models(for: settings.activeProvider).contains(where: { $0.id == modelId }) else { return }
        update { s in
            s.activeModelId = modelId
            s.preferredModels[s.activeProvider.rawValue] = modelId
        }
        NotificationCenter.default.post(name: Self.modelConfigChanged, object: nil)
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              let data = fm.contents(atPath: settingsURL.path) else { return }
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
            if !AvailableModels.models(for: settings.activeProvider).contains(where: { $0.id == settings.activeModelId }),
               let model = AvailableModels.defaultModel(for: settings.activeProvider) {
                settings.activeModelId = model.id
            }
        } catch {
            NSLog("[SettingsManager] Failed to decode settings: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("[SettingsManager] Failed to save settings: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
