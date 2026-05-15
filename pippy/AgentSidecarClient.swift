//
//  AgentSidecarClient.swift
//  pippy
//
//  Swift bridge to Pip's local browser/tool automation sidecar.
//

import Foundation

@MainActor
final class AgentSidecarClient {
    struct SidecarEvent: Codable {
        let step: String
        let status: String
        let detail: String?
    }

    struct Snapshot: Codable {
        let url: String?
        let title: String?
        let text: String?
    }

    struct RunResponse: Codable {
        let handled: Bool
        let completed: Bool
        let summary: String
        let events: [SidecarEvent]
        let snapshot: Snapshot?
    }

    private struct RunRequest: Codable {
        let goal: String
    }

    private struct ToolRunRequest: Codable {
        let action: String
        let args: [String: String]
    }

    private struct HealthResponse: Codable {
        let ok: Bool
    }

    private let baseURL = URL(string: "http://127.0.0.1:37373")!
    private let session: URLSession
    private var process: Process?

    init() {
        let configuration = URLSessionConfiguration.default
        // Browser automation often needs well over 8s before the HTTP response begins.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 320
        self.session = URLSession(configuration: configuration)
    }

    func ensureRunning() async throws {
        if await isHealthy() {
            return
        }

        try startSidecarProcess()

        for _ in 0..<24 {
            if await isHealthy() {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw NSError(
            domain: "AgentSidecarClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "pip agent sidecar did not start"]
        )
    }

    func runAgent(goal: String) async throws -> RunResponse {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("agent/run"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RunRequest(goal: goal))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RunResponse.self, from: data)
    }

    func runTool(_ toolCall: PipToolCall) async throws -> PipStructuredToolResult {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("tool/run"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ToolRunRequest(action: toolCall.action.rawValue, args: toolCall.args)
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(PipStructuredToolResult.self, from: data)
    }

    private func isHealthy() async -> Bool {
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent("health"))
            try validate(response: response, data: data)
            return (try? JSONDecoder().decode(HealthResponse.self, from: data).ok) == true
        } catch {
            return false
        }
    }

    private func startSidecarProcess() throws {
        if let process, process.isRunning {
            return
        }

        let sidecarDirectory = try Self.resolvedSidecarDirectoryURL()
        let nodeExecutable = Self.nodeExecutableURL()
        let process = Process()
        process.executableURL = nodeExecutable
        process.currentDirectoryURL = sidecarDirectory
        if nodeExecutable.path == "/usr/bin/env" {
            process.arguments = ["node", "server.js"]
        } else {
            process.arguments = ["server.js"]
        }
        var environment = ProcessInfo.processInfo.environment
        let standardExecutableDirectories =
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(standardExecutableDirectories):\(existingPath)"
        } else {
            environment["PATH"] = standardExecutableDirectories
        }
        environment["PIP_AGENT_SIDECAR_PORT"] = "37373"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let line = String(data: chunk, encoding: .utf8), !line.isEmpty else { return }
            print("🧩 Pip agent sidecar: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try process.run()
        self.process = process
    }

    private static func resolvedSidecarDirectoryURL() throws -> URL {
        let serverFileName = "server.js"

        if let override = ProcessInfo.processInfo.environment["PIP_AGENT_SIDECAR_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: overrideURL.appendingPathComponent(serverFileName).path) {
                return overrideURL
            }
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repositorySidecarURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agent-sidecar", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositorySidecarURL.appendingPathComponent(serverFileName).path) {
            return repositorySidecarURL
        }

        let bundleSidecarURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("agent-sidecar", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundleSidecarURL.appendingPathComponent(serverFileName).path) {
            return bundleSidecarURL
        }

        throw NSError(
            domain: "AgentSidecarClient",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey:
                """
                cannot find agent-sidecar (missing server.js). \
                Keep this repository on your Mac, or set PIP_AGENT_SIDECAR_DIR to the folder that contains server.js \
                (for example: export PIP_AGENT_SIDECAR_DIR=\"/path/to/your/project/agent-sidecar\" before launching Pip from Terminal).
                """
            ]
        )
    }

    private static func nodeExecutableURL() -> URL {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AgentSidecarClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "invalid sidecar response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AgentSidecarClient", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "sidecar request failed (\(httpResponse.statusCode)): \(body)"])
        }
    }
}
