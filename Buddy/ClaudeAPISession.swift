import Foundation

class ClaudeAPISession: AgentSession {
    private let config: ModelConfig
    private let sseParser = SSEParser()
    private var task: URLSessionDataTask?
    private var responseID = UUID()
    private var messages: [[String: Any]] = []
    private var currentResponseText = ""

    var isRunning = false
    var isBusy = false
    var history: [ChatMessage] = []

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    init(config: ModelConfig) {
        self.config = config
        sseParser.onEvent = { [weak self] json in
            self?.handleSSEEvent(json)
        }
    }

    func start() {
        guard let apiKey = config.apiKey else {
            onError?("No Anthropic API key configured. Add one in Settings.")
            return
        }
        guard !apiKey.isEmpty else {
            onError?("Anthropic API key is empty. Update it in Settings.")
            return
        }
        isRunning = true
        DispatchQueue.main.async { self.onSessionReady?() }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        guard isRunning else { return }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            onError?("No API key configured.")
            return
        }
        isBusy = true
        responseID = UUID()
        let responseID = self.responseID
        if !message.hasPrefix("<system>") {
            history.append(ChatMessage(role: .user, text: message))
        }

        // Build content
        var content: [Any] = []
        if let img = screenshotBase64 {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": img]
            ])
        }
        content.append(["type": "text", "text": message])

        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": config.modelId,
            "max_tokens": 1024,
            "system": buildBuddySystemPrompt(),
            "messages": messages,
            "stream": true,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onError?("Failed to build request.")
            isBusy = false
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        currentResponseText = ""
        sseParser.reset()

        let session = URLSession(configuration: .default, delegate: APIStreamDelegate(parser: sseParser, config: config, onError: { [weak self] message in
            guard self?.responseID == responseID else { return }
            self?.failResponse(message)
        }, onComplete: { [weak self] in
            guard self?.responseID == responseID else { return }
            self?.finishResponse()
        }), delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func terminate() {
        task?.cancel()
        isBusy = false
        isRunning = false
    }

    func handleSSEEvent(_ json: [String: Any]) {
        guard isBusy, isRunning else { return }
        if let message = APIResponseError.message(json, config: config) {
            failResponse(message)
            return
        }
        let eventType = json["type"] as? String ?? ""
        switch eventType {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                currentResponseText += text
                onText?(text)
            }

        case "message_stop":
            finishResponse()

        default:
            break
        }
    }

    private func failResponse(_ message: String) {
        guard isBusy, isRunning else { return }
        isBusy = false
        task?.cancel()
        onError?(message)
    }

    private func finishResponse() {
        guard isBusy, isRunning else { return }
        guard !currentResponseText.isEmpty else {
            failResponse("The API returned no response. Try again or choose another model in Settings.")
            return
        }
        isBusy = false
        let finalText = currentResponseText
        messages.append(["role": "assistant", "content": finalText])
        history.append(ChatMessage(role: .assistant, text: finalText))
        onTurnComplete?()
    }
}
