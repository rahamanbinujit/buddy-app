import AppKit
import AVFoundation

class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private static var current: SettingsWindow?

    private var providerButtons: [ModelProvider: NSButton] = [:]
    private var modelPopup: NSPopUpButton!
    private var statusLabel: NSTextField!

    private var apiKeyField: NSSecureTextField!
    private var apiKeyLabel: NSTextField!
    private var apiKeySaveBtn: NSButton!
    private var apiKeyDeleteBtn: NSButton!
    private var apiKeyProviderLabel: NSTextField!
    private var apiKeyHeader: NSTextField!
    private var apiKeyHintLabel: NSTextField!

    private var voiceHeader: NSTextField!
    private var voiceStatusLabel: NSTextField!
    private var voiceHintLabel: NSTextField!
    private var voiceSettingsBtn: NSButton!

    private var monitor: Any?

    init() {
        let W: CGFloat = 420
        let H: CGFloat = 480
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        center()

        let outer = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        outer.wantsLayer = true
        outer.layer?.backgroundColor = PetTheme.paper.cgColor
        outer.layer?.cornerRadius = 16
        outer.layer?.masksToBounds = true
        outer.layer?.borderWidth = 1
        outer.layer?.borderColor = PetTheme.milk.cgColor
        contentView = outer

        buildUI(in: outer, width: W, height: H)
        refreshState()
    }

    static func show() {
        if let existing = current, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = SettingsWindow()
        current = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.installMonitor()
    }

    // MARK: - Build UI

    private func buildUI(in outer: NSView, width W: CGFloat, height H: CGFloat) {
        let pad: CGFloat = 24
        var y = H - pad

        // Title
        y -= 28
        let title = makeLabel("Settings", size: 20, weight: .bold)
        title.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 28)
        outer.addSubview(title)

        // Close button
        let closeBtn = NSButton(frame: NSRect(x: W - pad - 24, y: y + 2, width: 24, height: 24))
        closeBtn.isBordered = false
        closeBtn.attributedTitle = NSAttributedString(
            string: "X",
            attributes: [
                .font: PetFonts.rounded(size: 14, weight: .bold),
                .foregroundColor: PetTheme.ink.withAlphaComponent(0.5)
            ]
        )
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        outer.addSubview(closeBtn)

        // MARK: Model Section
        y -= 32
        let modelHeader = makeSectionHeader("Model")
        modelHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(modelHeader)

        y -= 8
        let providers: [(ModelProvider, String)] = [
            (.claudeCLI, "Claude CLI"),
            (.claudeAPI, "Claude API"),
            (.openAI, "OpenAI"),
            (.gemini, "Gemini"),
        ]

        let btnW: CGFloat = 80
        let btnH: CGFloat = 30
        let gap: CGFloat = 6
        let totalBtnW = CGFloat(providers.count) * btnW + CGFloat(providers.count - 1) * gap
        var bx = (W - totalBtnW) / 2

        y -= btnH
        for (provider, label) in providers {
            let btn = NSButton(frame: NSRect(x: bx, y: y, width: btnW, height: btnH))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            btn.layer?.borderWidth = 1
            btn.layer?.borderColor = PetTheme.milk.cgColor
            btn.layer?.backgroundColor = PetTheme.milk.cgColor
            btn.attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .font: PetFonts.rounded(size: 10, weight: .medium),
                    .foregroundColor: PetTheme.ink,
                ]
            )
            btn.target = self
            btn.action = #selector(providerTapped(_:))
            providerButtons[provider] = btn
            outer.addSubview(btn)
            bx += btnW + gap
        }

        // Model dropdown
        y -= 38
        modelPopup = NSPopUpButton(frame: NSRect(x: pad, y: y, width: W - pad * 2, height: 28))
        modelPopup.isBordered = false
        modelPopup.wantsLayer = true
        modelPopup.layer?.backgroundColor = PetTheme.milk.cgColor
        modelPopup.layer?.cornerRadius = 8
        (modelPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        modelPopup.font = PetFonts.rounded(size: 12, weight: .medium)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        outer.addSubview(modelPopup)

        // Status
        y -= 22
        statusLabel = makeLabel("", size: 11, weight: .medium)
        statusLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(statusLabel)

        // MARK: API Keys Section
        y -= 32
        apiKeyHeader = makeSectionHeader("API Key")
        apiKeyHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(apiKeyHeader)

        y -= 22
        apiKeyProviderLabel = makeLabel("", size: 11, weight: .medium)
        apiKeyProviderLabel.textColor = PetTheme.ink.withAlphaComponent(0.5)
        apiKeyProviderLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(apiKeyProviderLabel)

        y -= 34
        apiKeyField = NSSecureTextField(frame: NSRect(x: pad, y: y, width: W - pad * 2 - 120, height: 28))
        apiKeyField.isBordered = false
        apiKeyField.wantsLayer = true
        apiKeyField.layer?.backgroundColor = PetTheme.milk.cgColor
        apiKeyField.layer?.cornerRadius = 8
        apiKeyField.font = PetFonts.mono(size: 11)
        apiKeyField.textColor = PetTheme.ink
        apiKeyField.backgroundColor = PetTheme.milk
        apiKeyField.focusRingType = .none
        apiKeyField.placeholderString = "sk-..."
        outer.addSubview(apiKeyField)

        apiKeySaveBtn = makeSmallButton("Save", action: #selector(saveAPIKey))
        apiKeySaveBtn.frame = NSRect(x: W - pad - 112, y: y, width: 52, height: 28)
        outer.addSubview(apiKeySaveBtn)

        apiKeyDeleteBtn = makeSmallButton("Delete", action: #selector(deleteAPIKey))
        apiKeyDeleteBtn.frame = NSRect(x: W - pad - 56, y: y, width: 52, height: 28)
        outer.addSubview(apiKeyDeleteBtn)

        y -= 22
        apiKeyHintLabel = makeLabel("", size: 10, weight: .regular)
        apiKeyHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
        apiKeyHintLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 14)
        outer.addSubview(apiKeyHintLabel)

        // MARK: Voice Section
        y -= 32
        voiceHeader = makeSectionHeader("Voice")
        voiceHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(voiceHeader)

        y -= 20
        voiceStatusLabel = makeLabel("", size: 11, weight: .medium)
        voiceStatusLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(voiceStatusLabel)

        y -= 20
        voiceHintLabel = makeLabel("Better voice: download a premium voice in System Settings > Accessibility > Spoken Content", size: 10, weight: .regular)
        voiceHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
        voiceHintLabel.lineBreakMode = .byWordWrapping
        voiceHintLabel.maximumNumberOfLines = 2
        voiceHintLabel.frame = NSRect(x: pad, y: y - 8, width: W - pad * 2 - 90, height: 28)
        outer.addSubview(voiceHintLabel)

        voiceSettingsBtn = makeSmallButton("Open", action: #selector(openVoiceSettings))
        voiceSettingsBtn.frame = NSRect(x: W - pad - 80, y: y - 4, width: 72, height: 24)
        outer.addSubview(voiceSettingsBtn)
    }

    // MARK: - State

    func refreshState() {
        let settings = SettingsManager.shared.settings
        let activeProvider = settings.activeProvider

        // Highlight active provider
        for (provider, btn) in providerButtons {
            if provider == activeProvider {
                btn.layer?.backgroundColor = PetTheme.shell.cgColor
                btn.layer?.borderColor = PetTheme.shell.cgColor
                btn.attributedTitle = NSAttributedString(
                    string: btn.attributedTitle.string,
                    attributes: [
                        .font: PetFonts.rounded(size: 10, weight: .bold),
                        .foregroundColor: NSColor.white,
                    ]
                )
            } else {
                btn.layer?.backgroundColor = PetTheme.milk.cgColor
                btn.layer?.borderColor = PetTheme.milk.cgColor
                btn.attributedTitle = NSAttributedString(
                    string: btn.attributedTitle.string,
                    attributes: [
                        .font: PetFonts.rounded(size: 10, weight: .medium),
                        .foregroundColor: PetTheme.ink,
                    ]
                )
            }
        }

        // Populate model dropdown
        modelPopup.removeAllItems()
        let models = AvailableModels.models(for: activeProvider)
        for model in models {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.id
        }
        if let idx = models.firstIndex(where: { $0.id == settings.activeModelId }) {
            modelPopup.selectItem(at: idx)
        }

        // Status indicator
        switch activeProvider {
        case .claudeCLI:
            let cliPaths = [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
            ]
            let cliFound = cliPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
            if cliFound {
                statusLabel.stringValue = "Claude CLI detected"
                statusLabel.textColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
            } else {
                statusLabel.stringValue = "Claude CLI not found — install it first"
                statusLabel.textColor = NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)
            }
        case .claudeAPI:
            let hasKey = KeychainHelper.apiKey(for: .claudeAPI) != nil
            statusLabel.stringValue = hasKey ? "API key saved" : "Add your Anthropic API key"
            statusLabel.textColor = hasKey
                ? NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
                : PetTheme.ink.withAlphaComponent(0.5)
        case .openAI:
            let hasKey = KeychainHelper.apiKey(for: .openAI) != nil
            statusLabel.stringValue = hasKey ? "API key saved" : "Add your OpenAI API key"
            statusLabel.textColor = hasKey
                ? NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
                : PetTheme.ink.withAlphaComponent(0.5)
        case .gemini:
            let hasKey = KeychainHelper.apiKey(for: .gemini) != nil
            statusLabel.stringValue = hasKey ? "API key saved" : "Add your Google AI API key"
            statusLabel.textColor = hasKey
                ? NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
                : PetTheme.ink.withAlphaComponent(0.5)
        case .buddyProxy:
            statusLabel.stringValue = "Select a provider above"
            statusLabel.textColor = PetTheme.ink.withAlphaComponent(0.5)
        }

        // API key section — visible for providers that need a key
        let needsKey = activeProvider.requiresAPIKey
        apiKeyHeader.isHidden = !needsKey
        apiKeyField.isHidden = !needsKey
        apiKeySaveBtn.isHidden = !needsKey
        apiKeyDeleteBtn.isHidden = !needsKey
        apiKeyProviderLabel.isHidden = !needsKey
        apiKeyHintLabel.isHidden = !needsKey

        if needsKey {
            let hasKey = KeychainHelper.apiKey(for: activeProvider) != nil
            apiKeyDeleteBtn.isHidden = !hasKey

            switch activeProvider {
            case .claudeAPI:
                apiKeyProviderLabel.stringValue = "Anthropic API Key"
                apiKeyField.placeholderString = "sk-ant-..."
                apiKeyHintLabel.stringValue = "Get one at console.anthropic.com"
            case .openAI:
                apiKeyProviderLabel.stringValue = "OpenAI API Key"
                apiKeyField.placeholderString = "sk-..."
                apiKeyHintLabel.stringValue = "Get one at platform.openai.com"
            case .gemini:
                apiKeyProviderLabel.stringValue = "Google AI API Key"
                apiKeyField.placeholderString = "AIza..."
                apiKeyHintLabel.stringValue = "Get one free at aistudio.google.com"
            default: break
            }
        }

        // Voice status
        let whisperPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil)
        let modelPath = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin")
        let whisperReady = whisperPath != nil && modelPath != nil
        // Also check fallback paths (for dev builds)
        let whisperAvailable = whisperReady
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")

        if whisperAvailable {
            voiceStatusLabel.stringValue = "Voice input ready (hold character to talk)"
            voiceStatusLabel.textColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
        } else {
            voiceStatusLabel.stringValue = "Voice unavailable — whisper model not found"
            voiceStatusLabel.textColor = NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)
        }

        // Check if a premium voice is available
        let hasPremium = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe") != nil
            || AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Samantha") != nil
        if hasPremium {
            voiceHintLabel.stringValue = "Premium voice detected — Buddy will sound great"
            voiceHintLabel.textColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
            voiceSettingsBtn.isHidden = true
        } else {
            voiceHintLabel.stringValue = "Tip: download a premium voice in System Settings > Accessibility > Spoken Content for better output"
            voiceHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
            voiceSettingsBtn.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func providerTapped(_ sender: NSButton) {
        guard let provider = providerButtons.first(where: { $0.value == sender })?.key else { return }
        apiKeyField.stringValue = ""
        SettingsManager.shared.setProvider(provider)
        refreshState()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let modelId = sender.selectedItem?.representedObject as? String else { return }
        SettingsManager.shared.setModel(modelId)
        refreshState()
    }

    @objc private func saveAPIKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let provider = SettingsManager.shared.settings.activeProvider
        guard KeychainHelper.saveAPIKey(key, for: provider) else {
            apiKeyHintLabel.stringValue = "Could not save the API key. Try again."
            return
        }
        NotificationCenter.default.post(name: SettingsManager.modelConfigChanged, object: nil)
        apiKeyField.stringValue = ""
        refreshState()
        apiKeyHintLabel.stringValue = "API key saved."
    }

    @objc private func deleteAPIKey() {
        let provider = SettingsManager.shared.settings.activeProvider
        guard KeychainHelper.deleteAPIKey(for: provider) else {
            apiKeyHintLabel.stringValue = "Could not delete the API key. Try again."
            return
        }
        NotificationCenter.default.post(name: SettingsManager.modelConfigChanged, object: nil)
        apiKeyField.stringValue = ""
        refreshState()
        apiKeyHintLabel.stringValue = "API key deleted."
    }

    @objc private func openVoiceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeTapped() {
        close()
    }

    override func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Self.current = nil
        orderOut(nil)
    }

    // MARK: - Monitor

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            if !self.frame.contains(loc) { self.close() }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        super.keyDown(with: event)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = PetFonts.rounded(size: size, weight: weight)
        label.textColor = PetTheme.ink
        label.alignment = alignment
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = PetFonts.rounded(size: 10, weight: .bold)
        label.textColor = PetTheme.ink.withAlphaComponent(0.4)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.layer?.backgroundColor = PetTheme.milk.cgColor
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: PetFonts.rounded(size: 11, weight: .medium),
                .foregroundColor: PetTheme.ink,
            ]
        )
        btn.target = self
        btn.action = action
        return btn
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
