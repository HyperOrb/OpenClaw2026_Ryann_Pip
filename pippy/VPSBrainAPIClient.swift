//
//  VPSBrainAPIClient.swift
//  pippy
//
//  Minimal remote brain client. Tries /respond first, then falls back to /plan.
//

import Foundation

final class VPSBrainAPIClient {
    struct ChatTurn: Codable {
        let user: String
        let assistant: String
    }

    struct RespondRequest: Codable {
        let task: String
        let systemPrompt: String
        let conversationHistory: [ChatTurn]
        let localToolResults: [String]
        let screenContext: [String]
    }

    struct RespondResponse: Codable {
        let text: String?
        let response: String?
        let message: String?
    }

    struct PlanResponse: Codable {
        let mode: String?
        let task: String?
        let steps: [String]?
        let error: String?
    }

    private var baseURL: URL
    private let session: URLSession

    init(baseURL: String = "http://localhost:3000") {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://localhost:3000")!
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: configuration)
    }

    func setBaseURL(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https") else {
            return
        }
        baseURL = url
    }

    func analyzeTask(
        task: String,
        systemPrompt: String,
        conversationHistory: [ChatTurn],
        localToolResults: [String],
        screenContext: [String]
    ) async throws -> String {
        return try await callRespondEndpoint(
            task: task,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            localToolResults: localToolResults,
            screenContext: screenContext
        )
    }

    private func callRespondEndpoint(
        task: String,
        systemPrompt: String,
        conversationHistory: [ChatTurn],
        localToolResults: [String],
        screenContext: [String]
    ) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("respond")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RespondRequest(
            task: task,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            localToolResults: localToolResults,
            screenContext: screenContext
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "VPSBrainAPIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid response from vps brain"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "VPSBrainAPIClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "vps /respond failed (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        let decoded = try JSONDecoder().decode(RespondResponse.self, from: data)
        let text = decoded.text ?? decoded.response ?? decoded.message ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "VPSBrainAPIClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "vps /respond returned empty text"]
            )
        }
        return trimmed
    }

    // Kept PlanResponse for compatibility if /plan is reused later.
}
