//
//  GroqAPIClient.swift
//  pippy
//
//  Optional Groq chat completions client for non-default cloud experiments.
//

import AppKit
import Foundation

final class GroqAPIClient {
    struct ChatTurn: Codable {
        let user: String
        let assistant: String
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_completion_tokens: Int
    }

    private struct VisionMessage: Encodable {
        let role: String
        let content: VisionContent
    }

    private enum VisionContent: Encodable {
        case text(String)
        case parts([VisionContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    private enum VisionContentPart: Encodable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        private struct ImageURLPayload: Encodable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURLPayload(url: url), forKey: .imageURL)
            }
        }
    }

    private struct VisionChatRequest: Encodable {
        let model: String
        let messages: [VisionMessage]
        let temperature: Double
        let max_completion_tokens: Int
    }

    private struct ChatResponse: Codable {
        struct Choice: Codable {
            struct ChoiceMessage: Codable {
                let role: String?
                let content: String?
            }
            let message: ChoiceMessage?
        }
        let choices: [Choice]
    }

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let session: URLSession
    private var apiKey: String = ""
    private(set) var model: String

    init(model: String = "llama-3.1-8b-instant") {
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func setAPIKey(_ value: String) {
        apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model = trimmed
    }

    func analyzeTask(
        systemPrompt: String,
        conversationHistory: [ChatTurn],
        userPrompt: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "GroqAPIClient",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "groq api key is missing. add it in pip settings."]
            )
        }

        var messages: [Message] = [.init(role: "system", content: systemPrompt)]
        for turn in conversationHistory.suffix(10) {
            messages.append(.init(role: "user", content: turn.user))
            messages.append(.init(role: "assistant", content: turn.assistant))
        }
        messages.append(.init(role: "user", content: userPrompt))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: messages,
                temperature: 0.4,
                max_completion_tokens: 450
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GroqAPIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid response from groq"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GroqAPIClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "groq request failed (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw NSError(
                domain: "GroqAPIClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "groq returned an empty response"]
            )
        }
        return text
    }

    func analyzeVisionTask(
        systemPrompt: String,
        userPrompt: String,
        images: [(data: Data, label: String)],
        modelOverride: String? = nil,
        maxCompletionTokens: Int = 700
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "GroqAPIClient",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "groq api key is missing. add it in pip settings."]
            )
        }

        var userParts: [VisionContentPart] = [.text(userPrompt)]
        for image in images.prefix(1) {
            userParts.append(.text("screenshot: \(image.label)"))
            let imageData = Self.compressedVisionImageData(from: image.data) ?? image.data
            let base64 = imageData.base64EncodedString()
            userParts.append(.imageURL("data:image/jpeg;base64,\(base64)"))
        }

        let requestBody = VisionChatRequest(
            model: modelOverride ?? model,
            messages: [
                .init(role: "system", content: .text(systemPrompt)),
                .init(role: "user", content: .parts(userParts))
            ],
            temperature: 0.1,
            max_completion_tokens: maxCompletionTokens
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GroqAPIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid response from groq"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GroqAPIClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "groq vision request failed (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw NSError(
                domain: "GroqAPIClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "groq returned an empty operator response"]
            )
        }
        return text
    }

    private static func compressedVisionImageData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let maxDimension: CGFloat = 720
        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let targetSize = CGSize(width: max(1, sourceWidth * scale), height: max(1, sourceHeight * scale))

        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: source, size: NSSize(width: sourceWidth, height: sourceHeight))
            .draw(in: CGRect(origin: .zero, size: targetSize))
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.45])
    }
}
