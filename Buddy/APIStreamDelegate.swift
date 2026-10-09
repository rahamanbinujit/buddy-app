import Foundation

struct APIResponseError {
    static func message(_ json: [String: Any], status: Int? = nil, config: ModelConfig) -> String? {
        guard json["error"] != nil || json["type"] as? String == "error" || status.map({ !(200..<300).contains($0) }) == true else { return nil }
        let error = json["error"] as? [String: Any]
        let detail = error?["message"] as? String ?? json["error"] as? String
            ?? status.map { "The API request failed (HTTP \($0))." } ?? "Unknown API error."
        let code = error?["code"] as? String ?? error?["type"] as? String ?? ""
        let errorStatus = status ?? error?["code"] as? Int
        let description = "\(code) \(detail)".lowercased()
        if errorStatus == 401 || errorStatus == 403 || description.contains("api key")
            || description.contains("api_key") || description.contains("authentication") {
            let action = config.provider.requiresAPIKey
                ? "Check your API key and permissions in Settings."
                : "Check your account in Settings > Account."
            return "\(detail) \(action)"
        }
        if errorStatus == 404 || description.contains("model") {
            return "\(detail) Model '\(config.modelId)' may be unavailable for this provider or account. Choose another model in Settings."
        }
        return detail
    }
}

// All API providers can return a JSON error body instead of an SSE stream.
class APIStreamDelegate: NSObject, URLSessionDataDelegate {
    private let parser: SSEParser
    private let config: ModelConfig
    private let onError: (String) -> Void
    private let onComplete: () -> Void
    private var httpStatus = 200
    private var errorBuffer = Data()

    init(parser: SSEParser, config: ModelConfig, onError: @escaping (String) -> Void, onComplete: @escaping () -> Void) {
        self.parser = parser
        self.config = config
        self.onError = onError
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !(200..<300).contains(httpStatus) {
            errorBuffer.append(data)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.parser.feed(text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if !(200..<300).contains(httpStatus) {
            let json = (try? JSONSerialization.jsonObject(with: errorBuffer)) as? [String: Any] ?? [:]
            let message = APIResponseError.message(json, status: httpStatus, config: config)!
            DispatchQueue.main.async { self.onError(message) }
        } else if let error = error {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async { self.onError("Connection failed: \(error.localizedDescription)") }
        } else {
            DispatchQueue.main.async { self.onComplete() }
        }
    }
}
