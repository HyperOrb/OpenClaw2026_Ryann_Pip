//
//  OllamaAgentClient.swift
//  pippy
//
//  Local Ollama chat client used by Pip's hackathon agent loop.
//

import Foundation

final class OllamaAgentClient {
    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(
        baseURL: String = "http://localhost:11434",
        model: String = "gemma3:latest"
    ) {
        self.apiURL = URL(string: "\(baseURL)/api/chat")!
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for historyEntry in conversationHistory {
            messages.append(["role": "user", "content": historyEntry.userPlaceholder])
            messages.append(["role": "assistant", "content": historyEntry.assistantResponse])
        }

        do {
            return try await streamResponse(
                messages: messages,
                userPrompt: userPrompt,
                images: images,
                onTextChunk: onTextChunk
            )
        } catch {
            let errorDescription = error.localizedDescription.lowercased()
            let shouldRetryWithoutImages = !images.isEmpty
                && (errorDescription.contains("does not support images")
                    || errorDescription.contains("vision")
                    || errorDescription.contains("multimodal"))
            guard shouldRetryWithoutImages else {
                throw error
            }

            return try await streamResponse(
                messages: messages,
                userPrompt: userPrompt + "\n\n(no screenshots attached because this model does not support image input.)",
                images: [],
                onTextChunk: onTextChunk
            )
        }
    }

    private func streamResponse(
        messages baseMessages: [[String: Any]],
        userPrompt: String,
        images: [(data: Data, label: String)],
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages = baseMessages
        if images.isEmpty {
            messages.append([
                "role": "user",
                "content": userPrompt
            ])
        } else {
            let imageLabels = images.map(\.label).joined(separator: "\n")
            let imageBase64Values = images.map { $0.data.base64EncodedString() }
            messages.append([
                "role": "user",
                "content": "\(imageLabels)\n\n\(userPrompt)",
                "images": imageBase64Values
            ])
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "options": [
                "temperature": 0.4,
                "num_predict": 700
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaAgentClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid response from local ollama"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines {
                errorLines.append(line)
            }
            let errorBody = errorLines.joined(separator: "\n")
            throw NSError(
                domain: "OllamaAgentClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ollama request failed (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""
        for try await line in byteStream.lines {
            guard let lineData = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let message = payload["message"] as? [String: Any],
               let textChunk = message["content"] as? String {
                accumulatedResponseText += textChunk
                let currentResponseText = accumulatedResponseText
                await onTextChunk(currentResponseText)
            }

            if let isDone = payload["done"] as? Bool, isDone {
                break
            }
        }

        return (text: accumulatedResponseText, duration: Date().timeIntervalSince(startTime))
    }
}
