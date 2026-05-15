//
//  ComputerOperatorAgent.swift
//  pippy
//
//  Local observe/act/verify loop for visible Mac control.
//

import AppKit
import Foundation

@MainActor
final class ComputerOperatorAgent {
    struct RunResult {
        let summary: String
        let completed: Bool
        let steps: [OperatorStepResult]
    }

    struct OperatorStepResult {
        let stepIndex: Int
        let actionDescription: String
        let observation: String
        let success: Bool
    }

    private enum OperatorActionKind: String, Codable {
        case click
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case type
        case hotkey
        case press
        case scroll
        case wait
        case done
        case blocked
    }

    private struct OperatorAction: Codable {
        let action: OperatorActionKind
        let x: Double?
        let y: Double?
        let screen: Int?
        let text: String?
        let key: String?
        let keys: [String]?
        let deltaY: Double?
        let milliseconds: Int?
        let reason: String?
        let summary: String?
    }

    private let ollamaAgentClient: OllamaAgentClient
    private let uiAutomationExecutor: UIAutomationExecutor
    private let maximumSteps = 16

    init(
        ollamaAgentClient: OllamaAgentClient,
        uiAutomationExecutor: UIAutomationExecutor
    ) {
        self.ollamaAgentClient = ollamaAgentClient
        self.uiAutomationExecutor = uiAutomationExecutor
    }

    func run(
        goal: String,
        conversationSummary: String,
        recordStep: @escaping (String) -> Void
    ) async throws -> RunResult {
        if let deterministicResult = await runDeterministicFallbackIfPossible(
            goal: goal,
            recordStep: recordStep
        ) {
            return deterministicResult
        }

        var actionHistory: [String] = []
        var stepResults: [OperatorStepResult] = []

        for stepIndex in 1...maximumSteps {
            try Task.checkCancellation()
            recordStep("operator: observe screen")

            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let focusedApp = uiAutomationExecutor.observeFocusedApp()
            let prompt = planningPrompt(
                goal: goal,
                conversationSummary: conversationSummary,
                focusedApp: focusedApp,
                actionHistory: actionHistory,
                stepIndex: stepIndex,
                captures: captures
            )

            recordStep("operator: ask local model for next action")
            let rawResponse: String
            do {
                rawResponse = try await requestNextAction(prompt: prompt, captures: captures, recordStep: recordStep)
            } catch {
                if let fallbackResult = await runDeterministicFallbackIfPossible(goal: goal, recordStep: recordStep) {
                    return fallbackResult
                }
                throw error
            }

            let action = try parseAction(rawResponse)
            let actionDescription = describe(action)
            recordStep("operator: \(actionDescription)")

            if isHardStopped(action: action, goal: goal) {
                let message = "i stopped before doing something risky: \(action.reason ?? actionDescription)."
                stepResults.append(.init(
                    stepIndex: stepIndex,
                    actionDescription: actionDescription,
                    observation: message,
                    success: false
                ))
                return RunResult(summary: message, completed: false, steps: stepResults)
            }

            switch action.action {
            case .done:
                let summary = action.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalSummary = summary?.isEmpty == false ? summary! : "done."
                return RunResult(summary: finalSummary, completed: true, steps: stepResults)
            case .blocked:
                let summary = action.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalSummary = summary?.isEmpty == false ? summary! : "i got blocked and need you to take over."
                return RunResult(summary: finalSummary, completed: false, steps: stepResults)
            default:
                let executionObservation = await execute(action, captures: captures)
                actionHistory.append("step \(stepIndex): \(actionDescription) -> \(executionObservation)")
                if actionHistory.count > 10 {
                    actionHistory.removeFirst(actionHistory.count - 10)
                }
                stepResults.append(.init(
                    stepIndex: stepIndex,
                    actionDescription: actionDescription,
                    observation: executionObservation,
                    success: true
                ))
                recordStep("operator: verify result")
                try? await Task.sleep(nanoseconds: 550_000_000)
            }
        }

        let summary = "i reached my step limit, but i made progress: \(actionHistory.suffix(3).joined(separator: "; "))"
        return RunResult(summary: summary, completed: false, steps: stepResults)
    }

    private func requestNextAction(
        prompt: String,
        captures: [CompanionScreenCapture],
        recordStep: @escaping (String) -> Void
    ) async throws -> String {
        let response = try await ollamaAgentClient.analyzeImageStreaming(
            images: captures.prefix(1).map { ($0.imageData, $0.label) },
            systemPrompt: Self.systemPrompt,
            conversationHistory: [],
            userPrompt: prompt,
            onTextChunk: { _ in }
        )
        return response.text
    }

    private func runDeterministicFallbackIfPossible(
        goal: String,
        recordStep: @escaping (String) -> Void
    ) async -> RunResult? {
        guard let searchText = extractSearchBarTypeText(from: goal) else {
            return nil
        }

        recordStep("operator: using local search-field fallback")
        let didFocusAndType = await uiAutomationExecutor.focusSearchFieldAndType(
            query: searchText,
            keywords: ["search", "find", "query", "address"],
            submit: false
        )

        if didFocusAndType {
            let step = OperatorStepResult(
                stepIndex: 1,
                actionDescription: "type into search field",
                observation: "focused an accessible search field and typed \(searchText)",
                success: true
            )
            return RunResult(
                summary: "done, i typed \(searchText) into the search bar.",
                completed: true,
                steps: [step]
            )
        }

        let observation = uiAutomationExecutor.observeFocusedApp()
        let physicalFallback = physicalSearchFallback(for: observation)
        recordStep("operator: using visible browser search fallback")
        let didClickAndType = await uiAutomationExecutor.clickApproximateSearchAreaAndType(
            query: searchText,
            verticalOffsetFromWindowTop: physicalFallback.yOffset,
            horizontalPositionInWindow: physicalFallback.xRatio,
            submit: shouldSubmitSearch(for: goal)
        )

        if didClickAndType {
            let step = OperatorStepResult(
                stepIndex: 1,
                actionDescription: "click visible search area and type",
                observation: "clicked approximate \(physicalFallback.description) search area in \(observation.appName) and typed \(searchText)",
                success: true
            )
            let suffix = shouldSubmitSearch(for: goal) ? " and submitted it" : ""
            return RunResult(
                summary: "done, i clicked the search area and typed \(searchText)\(suffix).",
                completed: true,
                steps: [step]
            )
        }

        return nil
    }

    private func physicalSearchFallback(
        for observation: UIAutomationExecutor.FocusedAppObservation
    ) -> (yOffset: CGFloat, xRatio: CGFloat, description: String) {
        let combinedText = [
            observation.appName,
            observation.bundleIdentifier ?? "",
            observation.focusedWindowTitle ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        if combinedText.contains("youtube") {
            return (105, 0.52, "youtube")
        }
        if combinedText.contains("google") {
            return (310, 0.50, "google")
        }
        if combinedText.contains("safari") || combinedText.contains("chrome") || combinedText.contains("browser") {
            return (52, 0.50, "browser address")
        }
        return (76, 0.50, "front window")
    }

    private func shouldSubmitSearch(for goal: String) -> Bool {
        let lowercased = goal.lowercased()
        return lowercased.contains("search for")
            || lowercased.contains("look up")
            || lowercased.contains("find ")
            || lowercased.contains("press enter")
            || lowercased.contains("submit")
            || lowercased.contains("hit enter")
    }

    private func extractSearchBarTypeText(from goal: String) -> String? {
        let lowercased = goal.lowercased()
        guard lowercased.contains("search bar") || lowercased.contains("search field") else {
            return nil
        }

        let markers = [
            "type ",
            "enter ",
            "write "
        ]

        for marker in markers {
            if let range = lowercased.range(of: marker) {
                let originalStartIndex = goal.index(goal.startIndex, offsetBy: lowercased.distance(from: lowercased.startIndex, to: range.upperBound))
                let text = String(goal[originalStartIndex...])
                    .replacingOccurrences(of: "for me", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".\"'")))
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    private static let systemPrompt = """
    you are pip's computer-use planner. you control a visible puppy paw cursor on the user's mac.

    choose exactly one next action. respond with only valid json. no markdown, no explanation outside json.

    coordinate rules:
    - screenshot coordinates use pixels.
    - origin is top-left.
    - x increases right.
    - y increases down.
    - choose coordinates from the screenshot image dimensions listed in the prompt.
    - use screen 1 unless the target is explicitly on another screenshot.

    allowed actions:
    {"action":"click","x":123,"y":456,"screen":1,"reason":"click the search field"}
    {"action":"double_click","x":123,"y":456,"screen":1,"reason":"open the file"}
    {"action":"right_click","x":123,"y":456,"screen":1,"reason":"open context menu"}
    {"action":"type","text":"hello world","reason":"fill the active text field"}
    {"action":"hotkey","keys":["command","l"],"reason":"focus address bar"}
    {"action":"press","key":"return","reason":"submit"}
    {"action":"scroll","deltaY":-6,"reason":"scroll down"}
    {"action":"wait","milliseconds":800,"reason":"wait for page to load"}
    {"action":"done","summary":"short user-facing completion summary"}
    {"action":"blocked","summary":"what blocked the task and what the user needs to do"}

    be ambitious and continue acting until the task is truly complete. if an action might send a message, buy something, delete files, empty trash, change passwords, or change privacy/security settings, return blocked instead of doing it.
    """

    private func planningPrompt(
        goal: String,
        conversationSummary: String,
        focusedApp: UIAutomationExecutor.FocusedAppObservation,
        actionHistory: [String],
        stepIndex: Int,
        captures: [CompanionScreenCapture]
    ) -> String {
        let captureInfo = captures.enumerated().map { index, capture in
            """
            screen \(index + 1): \(capture.label)
            image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels
            display frame in mac coordinates: x \(Int(capture.displayFrame.origin.x)), y \(Int(capture.displayFrame.origin.y)), width \(capture.displayWidthInPoints), height \(capture.displayHeightInPoints)
            """
        }.joined(separator: "\n\n")

        let history = actionHistory.isEmpty ? "none yet" : actionHistory.joined(separator: "\n")
        let focusedWindow = focusedApp.focusedWindowTitle ?? "unknown"
        return """
        user goal:
        \(goal)

        relevant conversation:
        \(conversationSummary.isEmpty ? "none" : conversationSummary)

        current focused app:
        app: \(focusedApp.appName)
        bundle: \(focusedApp.bundleIdentifier ?? "unknown")
        window: \(focusedWindow)

        operator step:
        \(stepIndex) of \(maximumSteps)

        recent action history:
        \(history)

        screenshots:
        \(captureInfo)

        decide the single best next action. if the goal is already complete from the screenshots, return done.
        """
    }

    private func parseAction(_ rawResponse: String) throws -> OperatorAction {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            jsonText = String(trimmed[firstBrace...lastBrace])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw NSError(domain: "ComputerOperatorAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "operator returned unreadable action"])
        }

        do {
            return try JSONDecoder().decode(OperatorAction.self, from: data)
        } catch {
            throw NSError(domain: "ComputerOperatorAgent", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "operator returned invalid action json: \(jsonText)"])
        }
    }

    private func execute(_ action: OperatorAction, captures: [CompanionScreenCapture]) async -> String {
        switch action.action {
        case .click:
            guard let point = screenPoint(for: action, captures: captures) else { return "missing click coordinate" }
            uiAutomationExecutor.moveMouse(to: point)
            await uiAutomationExecutor.wait(milliseconds: 160)
            uiAutomationExecutor.click(screenPoint: point)
            return "clicked at \(Int(point.x)), \(Int(point.y))"
        case .doubleClick:
            guard let point = screenPoint(for: action, captures: captures) else { return "missing double-click coordinate" }
            uiAutomationExecutor.moveMouse(to: point)
            await uiAutomationExecutor.wait(milliseconds: 160)
            uiAutomationExecutor.doubleClick(screenPoint: point)
            return "double-clicked at \(Int(point.x)), \(Int(point.y))"
        case .rightClick:
            guard let point = screenPoint(for: action, captures: captures) else { return "missing right-click coordinate" }
            uiAutomationExecutor.moveMouse(to: point)
            await uiAutomationExecutor.wait(milliseconds: 160)
            uiAutomationExecutor.rightClick(screenPoint: point)
            return "right-clicked at \(Int(point.x)), \(Int(point.y))"
        case .type:
            let text = action.text ?? ""
            await uiAutomationExecutor.typeTextVisibly(text)
            return "typed \(text.count) characters"
        case .hotkey:
            uiAutomationExecutor.pressShortcut(action.keys ?? [])
            return "pressed hotkey \((action.keys ?? []).joined(separator: "+"))"
        case .press:
            uiAutomationExecutor.pressNamedKey(action.key ?? "")
            return "pressed \(action.key ?? "key")"
        case .scroll:
            uiAutomationExecutor.scroll(deltaY: CGFloat(action.deltaY ?? 0))
            return "scrolled \(Int(action.deltaY ?? 0))"
        case .wait:
            await uiAutomationExecutor.wait(milliseconds: action.milliseconds ?? 800)
            return "waited \(action.milliseconds ?? 800) milliseconds"
        case .done, .blocked:
            return "no action needed"
        }
    }

    private func screenPoint(for action: OperatorAction, captures: [CompanionScreenCapture]) -> CGPoint? {
        guard let x = action.x, let y = action.y, !captures.isEmpty else { return nil }
        let captureIndex = max(0, min((action.screen ?? 1) - 1, captures.count - 1))
        let capture = captures[captureIndex]

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        guard screenshotWidth > 0, screenshotHeight > 0 else { return nil }

        let clampedX = max(0, min(CGFloat(x), screenshotWidth))
        let clampedY = max(0, min(CGFloat(y), screenshotHeight))
        let displayLocalX = clampedX * (CGFloat(capture.displayWidthInPoints) / screenshotWidth)
        let displayLocalY = clampedY * (CGFloat(capture.displayHeightInPoints) / screenshotHeight)
        let appKitY = CGFloat(capture.displayHeightInPoints) - displayLocalY

        return CGPoint(
            x: displayLocalX + capture.displayFrame.origin.x,
            y: appKitY + capture.displayFrame.origin.y
        )
    }

    private func describe(_ action: OperatorAction) -> String {
        let reason = action.reason ?? action.summary ?? ""
        switch action.action {
        case .click: return "click \(reason)"
        case .doubleClick: return "double-click \(reason)"
        case .rightClick: return "right-click \(reason)"
        case .type: return "type text"
        case .hotkey: return "press \((action.keys ?? []).joined(separator: "+"))"
        case .press: return "press \(action.key ?? "key")"
        case .scroll: return "scroll"
        case .wait: return "wait"
        case .done: return "done"
        case .blocked: return "blocked"
        }
    }

    private func isHardStopped(action: OperatorAction, goal: String) -> Bool {
        let searchableText = [
            action.reason,
            action.summary,
            action.text,
            goal
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        let dangerousPhrases = [
            "empty trash",
            "delete permanently",
            "erase",
            "format disk",
            "send message",
            "send email",
            "post",
            "purchase",
            "buy",
            "checkout",
            "payment",
            "password",
            "privacy",
            "security settings"
        ]

        return dangerousPhrases.contains { searchableText.contains($0) }
    }
}
