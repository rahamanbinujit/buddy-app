import XCTest
@testable import Buddy

final class APISessionTests: XCTestCase {
    func testStreamErrorsEndEachProviderTurnWithoutSuccess() {
        let error: [String: Any] = ["error": ["message": "Model not found", "code": 404]]
        let configs = [ModelProvider.gemini, .claudeAPI, .openAI, .buddyProxy].map {
            ModelConfig(provider: $0, modelId: "retired-model", displayName: "Test", apiKey: "test-key")
        }
        let gemini = GeminiSession(config: configs[0])
        let claude = ClaudeAPISession(config: configs[1])
        let openAI = OpenAISession(config: configs[2])
        let proxy = ProxySession(config: configs[3])
        gemini.isRunning = true; gemini.isBusy = true
        claude.isRunning = true; claude.isBusy = true
        openAI.isRunning = true; openAI.isBusy = true
        proxy.isRunning = true; proxy.isBusy = true
        let sessions: [AgentSession] = [gemini, claude, openAI, proxy]
        var errors = 0
        for session in sessions {
            session.onError = { message in
                XCTAssertTrue(message.contains("retired-model"))
                XCTAssertTrue(message.contains("Settings"))
                errors += 1
            }
            session.onTurnComplete = { XCTFail("Error must not complete successfully") }
        }
        gemini.handleSSEEvent(error)
        claude.handleSSEEvent(error)
        openAI.handleSSEEvent(error)
        proxy.handleSSEEvent(error)
        // Late completion events after an error must be ignored.
        gemini.handleSSEEvent(["candidates": [["content": ["parts": [["text": "late"]]], "finishReason": "STOP"]]])
        claude.handleSSEEvent(["type": "message_stop"])
        openAI.handleSSEEvent(["choices": [["finish_reason": "stop"]]])
        proxy.handleSSEEvent(["type": "done"])
        XCTAssertEqual(errors, 4)
        XCTAssertTrue(sessions.allSatisfy { !$0.isBusy && $0.history.isEmpty })
    }

    func testGeminiSuccessfulTurnCompletesOnlyOnce() {
        let config = ModelConfig(provider: .gemini, modelId: "test-model", displayName: "Test")
        let session = GeminiSession(config: config)
        session.isRunning = true; session.isBusy = true
        var text = ""
        var completions = 0
        session.onText = { text += $0 }
        session.onError = { XCTFail($0) }
        session.onTurnComplete = { completions += 1 }
        let event: [String: Any] = ["candidates": [["content": ["parts": [["text": "Hello"]]], "finishReason": "STOP"]]]
        session.handleSSEEvent(event)
        session.handleSSEEvent(event)
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.history.count, 1)
    }
}
