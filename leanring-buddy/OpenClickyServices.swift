import Foundation
import Security

enum OpenClickyAIProvider: String, CaseIterable, Identifiable {
    case chatGPT
    case openAI
    case anthropic
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT Plan"
        case .openAI: return "OpenAI API"
        case .anthropic: return "Anthropic API"
        case .gemini: return "Gemini API"
        case .ollama: return "Ollama"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .gemini: return true
        case .chatGPT, .ollama: return false
        }
    }

    var defaultModel: String {
        switch self {
        case .chatGPT, .openAI: return "gpt-5.2"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "llava"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .chatGPT, .openAI: return ["gpt-5.2", "gpt-5.1", "gpt-4.1"]
        case .anthropic: return ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .ollama: return ["llava", "llama3.2-vision", "qwen2.5vl"]
        }
    }
}

enum OpenClickySpeechOutput: String, CaseIterable, Identifiable {
    case macVoice
    case localKokoro
    case textOnly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .macVoice: return "Mac Voice"
        case .localKokoro: return "Kokoro Local"
        case .textOnly: return "Text Only"
        }
    }
}

enum OpenClickyCredentialStore {
    private static let service = "org.openclicky.provider-credentials"

    static func apiKey(for provider: OpenClickyAIProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func saveAPIKey(_ apiKey: String, for provider: OpenClickyAIProvider) throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            deleteAPIKey(for: provider)
            return
        }

        let query = baseQuery(for: provider)
        let attributes = [kSecValueData as String: Data(trimmedAPIKey.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = Data(trimmedAPIKey.utf8)
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }

    static func deleteAPIKey(for provider: OpenClickyAIProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }

    private static func baseQuery(for provider: OpenClickyAIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}

struct OpenClickyProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class OpenClickyDirectAIClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func listModels(
        provider: OpenClickyAIProvider,
        apiKey: String?
    ) async throws -> [OpenAIModelOption] {
        let request: URLRequest
        switch provider {
        case .chatGPT:
            return []
        case .openAI:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            var openAIRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            openAIRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request = openAIRequest
        case .anthropic:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            var anthropicRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            anthropicRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            anthropicRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request = anthropicRequest
        case .gemini:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            var geminiRequest = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            geminiRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request = geminiRequest
        case .ollama:
            request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        }

        let payload = try await sendJSONRequest(request)
        let modelDictionaries: [[String: Any]]
        if provider == .gemini {
            modelDictionaries = payload["models"] as? [[String: Any]] ?? []
        } else {
            modelDictionaries = payload["data"] as? [[String: Any]]
                ?? payload["models"] as? [[String: Any]]
                ?? []
        }

        return modelDictionaries.compactMap { modelDictionary in
            let rawModelID = modelDictionary["id"] as? String
                ?? modelDictionary["name"] as? String
                ?? modelDictionary["slug"] as? String
            guard let rawModelID else { return nil }
            let modelID = rawModelID.replacingOccurrences(of: "models/", with: "")
            if provider == .openAI,
               !modelID.hasPrefix("gpt-"),
               !modelID.hasPrefix("o") {
                return nil
            }
            if provider == .gemini,
               let supportedMethods = modelDictionary["supportedGenerationMethods"] as? [String],
               !supportedMethods.contains("generateContent") {
                return nil
            }
            return OpenAIModelOption(
                id: modelID,
                displayName: modelDictionary["display_name"] as? String
                    ?? modelDictionary["displayName"] as? String
                    ?? modelID
            )
        }
    }

    func respond(
        provider: OpenClickyAIProvider,
        model: String,
        apiKey: String?,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        switch provider {
        case .chatGPT:
            throw OpenClickyProviderError(message: "ChatGPT Plan requests use the authenticated client.")
        case .openAI:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            return try await openAIResponse(
                apiKey: apiKey,
                model: model,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        case .anthropic:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            return try await anthropicResponse(
                apiKey: apiKey,
                model: model,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        case .gemini:
            guard let apiKey else { throw missingAPIKeyError(provider) }
            return try await geminiResponse(
                apiKey: apiKey,
                model: model,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        case .ollama:
            return try await ollamaResponse(
                model: model,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        }
    }

    private func openAIResponse(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        var input: [[String: Any]] = conversationHistory.flatMap { entry in
            [
                ["role": "user", "content": [["type": "input_text", "text": entry.userPlaceholder]]],
                ["role": "assistant", "content": [["type": "output_text", "text": entry.assistantResponse]]]
            ]
        }
        var content: [[String: Any]] = images.flatMap { image in
            [
                ["type": "input_text", "text": image.label],
                ["type": "input_image", "image_url": dataURL(for: image.data)]
            ]
        }
        content.append(["type": "input_text", "text": userPrompt])
        input.append(["role": "user", "content": content])

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": systemPrompt,
            "input": input,
            "store": false
        ])

        let payload = try await sendJSONRequest(request)
        if let outputText = payload["output_text"] as? String { return outputText }
        let output = payload["output"] as? [[String: Any]] ?? []
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw invalidResponseError(providerName: "OpenAI") }
        return text
    }

    private func anthropicResponse(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        var messages: [[String: Any]] = conversationHistory.flatMap { entry in
            [
                ["role": "user", "content": entry.userPlaceholder],
                ["role": "assistant", "content": entry.assistantResponse]
            ]
        }
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "text", "text": image.label])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": content])

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1200,
            "system": systemPrompt,
            "messages": messages
        ])

        let payload = try await sendJSONRequest(request)
        let text = (payload["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw invalidResponseError(providerName: "Anthropic") }
        return text
    }

    private func geminiResponse(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")!

        var contents: [[String: Any]] = conversationHistory.flatMap { entry in
            [
                ["role": "user", "parts": [["text": entry.userPlaceholder]]],
                ["role": "model", "parts": [["text": entry.assistantResponse]]]
            ]
        }
        var parts: [[String: Any]] = []
        for image in images {
            parts.append(["text": image.label])
            parts.append([
                "inlineData": [
                    "mimeType": mediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        parts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": parts])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents
        ])

        let payload = try await sendJSONRequest(request)
        let candidates = payload["candidates"] as? [[String: Any]] ?? []
        let responseParts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = responseParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw invalidResponseError(providerName: "Gemini") }
        return text
    }

    private func ollamaResponse(
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for entry in conversationHistory {
            messages.append(["role": "user", "content": entry.userPlaceholder])
            messages.append(["role": "assistant", "content": entry.assistantResponse])
        }
        messages.append([
            "role": "user",
            "content": images.map(\.label).joined(separator: "\n") + "\n" + userPrompt,
            "images": images.map { $0.data.base64EncodedString() }
        ])

        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "stream": false
        ])

        let payload = try await sendJSONRequest(request)
        guard let message = payload["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty else {
            throw invalidResponseError(providerName: "Ollama")
        }
        return text
    }

    private func sendJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenClickyProviderError(message: "Provider request failed (\(statusCode)): \(responseText)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClickyProviderError(message: "The provider returned an invalid response.")
        }
        return payload
    }

    private func dataURL(for data: Data) -> String {
        "data:\(mediaType(for: data));base64,\(data.base64EncodedString())"
    }

    private func mediaType(for data: Data) -> String {
        Array(data.prefix(4)) == [0x89, 0x50, 0x4e, 0x47] ? "image/png" : "image/jpeg"
    }

    private func missingAPIKeyError(_ provider: OpenClickyAIProvider) -> OpenClickyProviderError {
        OpenClickyProviderError(message: "Add your \(provider.displayName) key in the OpenClicky menu.")
    }

    private func invalidResponseError(providerName: String) -> OpenClickyProviderError {
        OpenClickyProviderError(message: "\(providerName) returned a response without text.")
    }
}
