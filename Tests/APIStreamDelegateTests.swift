import XCTest
@testable import Buddy

final class APIStreamDelegateTests: XCTestCase {
    private let config = ModelConfig(provider: .gemini, modelId: "retired-model", displayName: "Test")

    func testHTTPFailuresAlwaysSurfaceAndNeverComplete() {
        for (status, body) in [(401, "{\"error\":{\"message\":\"Invalid credentials\"}}"),
                               (403, ""), (404, "{\"error\":\"Unknown model\"}"),
                               (429, "{\"error\":{\"message\":\"Rate limit\"}}"), (500, "not JSON")] {
            let failed = expectation(description: "HTTP \(status)")
            let parser = SSEParser()
            parser.onEvent = { _ in XCTFail("HTTP error body must not reach SSE parser") }
            let delegate = APIStreamDelegate(parser: parser, config: config, onError: { message in
                XCTAssertFalse(message.isEmpty)
                if status == 401 || status == 403 { XCTAssertTrue(message.contains("Settings")) }
                if status == 404 { XCTAssertTrue(message.contains("retired-model")) }
                failed.fulfill()
            }, onComplete: { XCTFail("Failed request must not complete successfully") })
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: URL(string: "https://example.invalid")!)
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
            let bytes = Data(body.utf8)
            delegate.urlSession(session, dataTask: task, didReceive: bytes.prefix(bytes.count / 2))
            delegate.urlSession(session, dataTask: task, didReceive: bytes.suffix(bytes.count - bytes.count / 2))
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            wait(for: [failed], timeout: 2)
        }
    }

    func testTransportFailureSurfacesWithoutCompletion() {
        let failed = expectation(description: "Connection failure")
        let delegate = APIStreamDelegate(parser: SSEParser(), config: config, onError: { message in
            XCTAssertTrue(message.contains("Connection failed"))
            failed.fulfill()
        }, onComplete: { XCTFail("Transport failure must not complete") })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid")!)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.notConnectedToInternet))
        wait(for: [failed], timeout: 2)
    }

    func testStreamErrorMessagesIncludeSettingsActions() {
        for provider in [ModelProvider.gemini, .claudeAPI, .openAI, .buddyProxy] {
            let config = ModelConfig(provider: provider, modelId: "retired-model", displayName: "Test")
            let keyError: [String: Any] = ["error": ["type": "authentication_error", "message": "Invalid credentials"]]
            XCTAssertTrue(APIResponseError.message(keyError, config: config)!.contains("Settings"))
            let modelError: [String: Any] = ["error": ["code": "model_not_found", "message": "Unavailable"]]
            XCTAssertTrue(APIResponseError.message(modelError, config: config)!.contains("Choose another model in Settings"))
            XCTAssertNil(APIResponseError.message(["candidates": []], config: config))
        }
    }
}
