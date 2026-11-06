import Foundation
import Security

/// Keeps the Claude API key in the login keychain, never in preferences or files.
public enum APIKeyStore {
    static let service = "Sweep Claude API key"
    static let account = "default"

    public static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Calls the Claude Messages API over HTTPS. Requests and responses are plain JSON objects, so the
/// assistant can send each response's content back unchanged, as the API expects.
public struct ClaudeClient: Sendable {
    public static let model = "claude-opus-5-5"
    let key: String

    public init(key: String) { self.key = key }

    public enum Failure: Error, LocalizedError {
        case http(Int, String)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .http(401, _): return "The API key was refused. Check it in Settings."
            case .http(429, _): return "Claude is rate limited right now. Try again in a minute."
            case .http(let code, let message): return "Claude returned an error (\(code)): \(message)"
            case .malformed: return "Claude's reply couldn't be read."
            }
        }
    }

    /// One request. Returns the response object (content, stop_reason, usage…) as parsed JSON.
    public func send(system: String, tools: [[String: Any]], messages: [[String: Any]]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines, the API retries on a suitable model within the same call.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "system": system,
            "tools": tools,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure.http(status, message)
        }
        guard let object else { throw Failure.malformed }
        return object
    }
}
