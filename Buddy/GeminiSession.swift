import Foundation

class GeminiSession: AgentSession {
    private let config: ModelConfig
    private var task: URLSessionDataTask?
    private var responseID = UUID()
    private var messages: [[String: Any]] = []
    private var currentResponseText = ""
    private var responseBuffer = ""

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
    }

    func start() {
        guard let apiKey = config.apiKey else {
            onError?("No Gemini API key configured. Add one in Settings.")
            return
        }
        guard !apiKey.isEmpty else {
            onError?("Gemini API key is empty. Update it in Settings.")
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

        // Build user content parts
        var parts: [[String: Any]] = []
        if let img = screenshotBase64 {
            parts.append([
                "inline_data": ["mime_type": "image/jpeg", "data": img]
            ])
        }
        parts.append(["text": message])

        messages.append(["role": "user", "parts": parts])

        let body: [String: Any] = [
            "contents": messages,
            "systemInstruction": ["parts": [["text": buildBuddySystemPrompt()]]],
            "generationConfig": ["maxOutputTokens": 1024],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onError?("Failed to build request.")
            isBusy = false
            return
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(config.modelId):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            onError?("Invalid model ID.")
            isBusy = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        currentResponseText = ""
        responseBuffer = ""

        let sseParser = SSEParser()
        sseParser.onEvent = { [weak self] json in
            self?.handleSSEEvent(json)
        }

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
        // Gemini streaming response: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return }

        for part in parts {
            if let text = part["text"] as? String {
                currentResponseText += text
                onText?(text)
            }
        }

        // Check if this is the final chunk
        if let finishReason = first["finishReason"] as? String, finishReason == "STOP" {
            finishResponse()
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
        messages.append(["role": "model", "parts": [["text": finalText]]])
        history.append(ChatMessage(role: .assistant, text: finalText))
        onTurnComplete?()
    }
}
