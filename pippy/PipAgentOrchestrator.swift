//
//  PipAgentOrchestrator.swift
//  pippy
//
//  Pip's first real plan-act-observe-verify loop.
//

import Foundation

@MainActor
final class PipAgentOrchestrator {
    private let plannerClient: PipCloudPlannerClient
    private let sidecarClient: AgentSidecarClient
    private let nativeToolExecutor: NativeToolExecutor
    private let maximumSteps = 4

    init(
        plannerClient: PipCloudPlannerClient,
        sidecarClient: AgentSidecarClient,
        nativeToolExecutor: NativeToolExecutor
    ) {
        self.plannerClient = plannerClient
        self.sidecarClient = sidecarClient
        self.nativeToolExecutor = nativeToolExecutor
    }

    static func shouldHandle(goal: String) -> Bool {
        let lower = goal.lowercased()
        let signals = [
            "teach me",
            "how do i use",
            "what do i click",
            "guide me",
            "summarize this page",
            "summarize the page",
            "summarize this webpage",
            "summarize this website",
            "youtube",
            "google",
            "search for",
            "look up",
            "open safari",
            "open chrome",
            "open terminal",
            "open xcode",
            "open finder",
            "open notes",
            "open calendar",
            "open reminders",
            "remind me",
            "set a reminder",
            "create a reminder",
            "take a note",
            "create note",
            "calendar event",
            "clean up my desktop",
            "cleanup my desktop",
            "organize my desktop"
        ]
        return signals.contains { lower.contains($0) }
    }

    func run(
        goal: String,
        conversationSummary: String,
        recordStep: @escaping (String) -> Void
    ) async -> PipAgentLoopResult {
        guard Self.shouldHandle(goal: goal) else {
            return PipAgentLoopResult(handled: false, completed: false, summary: "", toolResults: [])
        }

        var observations = [nativeToolExecutor.observeDesktop()]
        var toolResults: [PipStructuredToolResult] = []

        for step in 1...maximumSteps {
            recordStep("planning with cloud brain (\(step)/\(maximumSteps))")
            let toolCall = await plannerClient.planNextAction(
                goal: goal,
                conversationSummary: conversationSummary,
                observations: observations
            )
            recordStep("planner: \(toolCall.thoughtSummary)")

            if toolCall.requiresConfirmation || toolCall.action == .askConfirmation {
                let reason = toolCall.args["reason"] ?? "this action needs confirmation"
                let result = PipStructuredToolResult(
                    success: false,
                    action: .askConfirmation,
                    observation: reason,
                    url: nil,
                    title: nil,
                    text: nil,
                    needsConfirmation: true,
                    error: nil
                )
                toolResults.append(result)
                recordStep("blocked: needs confirmation — \(reason)")
                return PipAgentLoopResult(
                    handled: true,
                    completed: false,
                    summary: "i paused because \(reason).",
                    toolResults: toolResults
                )
            }

            if toolCall.action == .finalAnswer {
                let text: String
                if let plannedText = toolCall.args["text"], !plannedText.isEmpty {
                    text = plannedText
                } else {
                    text = await plannerClient.finalAnswer(
                        goal: goal,
                        observations: observations,
                        toolResults: toolResults
                    )
                }
                return PipAgentLoopResult(handled: true, completed: true, summary: text, toolResults: toolResults)
            }

            let result = await execute(toolCall)
            toolResults.append(result)
            observations.append(result.agentLogLine)
            recordStep(result.agentLogLine)

            if result.needsConfirmation {
                return PipAgentLoopResult(
                    handled: true,
                    completed: false,
                    summary: result.observation,
                    toolResults: toolResults
                )
            }

            if result.success {
                let summary = await plannerClient.finalAnswer(
                    goal: goal,
                    observations: observations,
                    toolResults: toolResults
                )
                return PipAgentLoopResult(handled: true, completed: true, summary: summary, toolResults: toolResults)
            }
        }

        let summary = await plannerClient.finalAnswer(
            goal: goal,
            observations: observations,
            toolResults: toolResults
        )
        return PipAgentLoopResult(handled: true, completed: false, summary: summary, toolResults: toolResults)
    }

    private func execute(_ toolCall: PipToolCall) async -> PipStructuredToolResult {
        switch toolCall.action {
        case .browserOpen, .browserSearch, .browserSnapshot, .browserClick, .browserFill,
                .browserPress, .browserExtractPageText, .browserVerifyText:
            do {
                return try await sidecarClient.runTool(toolCall)
            } catch {
                return PipStructuredToolResult(
                    success: false,
                    action: toolCall.action,
                    observation: "browser sidecar failed: \(error.localizedDescription)",
                    url: nil,
                    title: nil,
                    text: nil,
                    needsConfirmation: false,
                    error: error.localizedDescription
                )
            }
        case .macOpenApp, .macOpenURL, .macCreateReminder, .macCreateNote,
                .macCreateCalendarEvent, .filesListDesktop, .filesOrganizeDesktopPlan:
            return await nativeToolExecutor.executeStructuredTool(toolCall)
        case .screenTutor:
            return await tutorCurrentScreen(focus: toolCall.args["focus"] ?? "")
        case .finalAnswer, .askConfirmation:
            return PipStructuredToolResult(
                success: false,
                action: toolCall.action,
                observation: "not executable",
                url: nil,
                title: nil,
                text: nil,
                needsConfirmation: toolCall.action == .askConfirmation,
                error: nil
            )
        }
    }

    private func tutorCurrentScreen(focus: String) async -> PipStructuredToolResult {
        let desktopObservation = nativeToolExecutor.observeDesktop()
        let hasScreenshot = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().isEmpty == false) ?? false
        let observation = """
        i can guide you from here. \(desktopObservation). \(hasScreenshot ? "i can see the current screen, so start by looking at the main controls in the active window." : "screen capture is unavailable, so i can guide from the active app name for now.") tell me "do it" when you want me to act, or ask "what should i click" for the next step.
        """
        return PipStructuredToolResult(
            success: true,
            action: .screenTutor,
            observation: observation,
            url: nil,
            title: "Screen tutor",
            text: focus,
            needsConfirmation: false,
            error: nil
        )
    }
}
