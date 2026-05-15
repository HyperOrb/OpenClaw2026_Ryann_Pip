//
//  PipCloudPlannerClient.swift
//  pippy
//
//  Strong-model planner for Pip's plan-act-observe loop, with local
//  deterministic fallbacks for common voice-assistant tasks.
//

import Foundation

final class PipCloudPlannerClient {
    private let groqAPIClient: GroqAPIClient

    init(groqAPIClient: GroqAPIClient) {
        self.groqAPIClient = groqAPIClient
    }

    func planNextAction(
        goal: String,
        conversationSummary: String,
        observations: [String]
    ) async -> PipToolCall {
        if let deterministic = Self.fallbackPlan(for: goal, observations: observations) {
            return deterministic
        }

        do {
            let prompt = """
            You are Pip's planner. Pick exactly one next tool action for the user's goal.

            User goal:
            \(goal)

            Recent conversation:
            \(conversationSummary.isEmpty ? "none" : conversationSummary)

            Observations:
            \(observations.isEmpty ? "none" : observations.joined(separator: "\n"))

            Allowed actions:
            final.answer, safety.confirm, browser.open, browser.search, browser.snapshot,
            browser.click, browser.fill, browser.press, browser.extractPageText, browser.verifyText,
            mac.openApp, mac.openURL, mac.createReminder, mac.createNote, mac.createCalendarEvent,
            files.listDesktop, files.organizeDesktopPlan, screen.tutor

            Return strict JSON only:
            {
              "thought_summary": "short step summary for UI",
              "action": "browser.search",
              "args": { "site": "youtube", "query": "rockets" },
              "requires_confirmation": false,
              "success_condition": "results page is visible"
            }
            """

            let response = try await groqAPIClient.analyzeTask(
                systemPrompt: "You are a tool planner. Return only valid JSON. Never include markdown.",
                conversationHistory: [],
                userPrompt: prompt
            )
            if let parsed = Self.parseToolCall(from: response) {
                return parsed
            }
        } catch {
            // Fall through to a safe final answer instead of making Pip hang.
        }

        return PipToolCall(
            thoughtSummary: "answer directly",
            action: .finalAnswer,
            args: ["text": "i can help with that, but i need a little more specific instruction about what to do first."],
            requiresConfirmation: false,
            successCondition: "user gets a clear next step"
        )
    }

    func finalAnswer(
        goal: String,
        observations: [String],
        toolResults: [PipStructuredToolResult]
    ) async -> String {
        let successfulTool = toolResults.last(where: { $0.success })
        let failedTool = toolResults.last(where: { !$0.success })

        if let failedTool, successfulTool == nil {
            return "i tried, but \(failedTool.observation)"
        }

        if let successfulTool {
            switch successfulTool.action {
            case .browserSearch:
                return "done, i searched it and verified the results page."
            case .browserOpen:
                return "done, i opened it in the browser."
            case .browserExtractPageText:
                let text = (successfulTool.text ?? successfulTool.observation).prefix(420)
                return "here's what this page is about: \(text)"
            case .macOpenApp:
                return "done, i opened it."
            case .macCreateReminder:
                return "done, i created the reminder."
            case .macCreateNote:
                return "done, i created the note."
            case .macCreateCalendarEvent:
                return "done, i added it to your calendar."
            case .screenTutor:
                return successfulTool.observation
            case .filesOrganizeDesktopPlan:
                return successfulTool.observation
            default:
                break
            }
        }

        do {
            return try await groqAPIClient.analyzeTask(
                systemPrompt: "You are Pip, a concise spoken Mac assistant. Answer naturally in one or two sentences.",
                conversationHistory: [],
                userPrompt: """
                User goal: \(goal)
                Tool observations:
                \(observations.joined(separator: "\n"))
                Summarize what happened and the next useful step.
                """
            )
        } catch {
            return "i thought through it, but i could not finish that task yet."
        }
    }

    private static func parseToolCall(from text: String) -> PipToolCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[firstBrace...lastBrace])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PipToolCall.self, from: data)
    }

    private static func fallbackPlan(for goal: String, observations: [String]) -> PipToolCall? {
        let lower = goal.lowercased()
        if isRisky(goal: lower) {
            return PipToolCall(
                thoughtSummary: "pause for safety",
                action: .askConfirmation,
                args: ["reason": "this could change files, send something, spend money, or alter security settings"],
                requiresConfirmation: true,
                successCondition: "user confirms before risky action"
            )
        }

        if lower.contains("teach me")
            || lower.contains("how do i use")
            || lower.contains("what do i click")
            || lower.contains("guide me") {
            return PipToolCall(
                thoughtSummary: "explain the current screen",
                action: .screenTutor,
                args: ["focus": goal],
                requiresConfirmation: false,
                successCondition: "user receives screen-aware guidance"
            )
        }

        if lower.contains("summarize") && (lower.contains("page") || lower.contains("website") || lower.contains("webpage")) {
            return PipToolCall(
                thoughtSummary: "read current page",
                action: .browserExtractPageText,
                args: [:],
                requiresConfirmation: false,
                successCondition: "page text is extracted"
            )
        }

        if lower.contains("clean up my desktop")
            || lower.contains("cleanup my desktop")
            || lower.contains("organize my desktop") {
            return PipToolCall(
                thoughtSummary: "plan desktop organization",
                action: .filesOrganizeDesktopPlan,
                args: [:],
                requiresConfirmation: true,
                successCondition: "desktop cleanup plan is shown before moving files"
            )
        }

        if let search = extractSearch(goal: goal) {
            return PipToolCall(
                thoughtSummary: "search the web",
                action: .browserSearch,
                args: ["site": search.site, "query": search.query],
                requiresConfirmation: false,
                successCondition: "\(search.site) results for \(search.query) are visible"
            )
        }

        if let appName = extractAppOpen(goal: goal) {
            return PipToolCall(
                thoughtSummary: "open app",
                action: .macOpenApp,
                args: ["app": appName],
                requiresConfirmation: false,
                successCondition: "\(appName) is running"
            )
        }

        if lower.contains("remind me") || lower.contains("set a reminder") || lower.contains("create a reminder") {
            return PipToolCall(
                thoughtSummary: "create reminder",
                action: .macCreateReminder,
                args: ["text": goal],
                requiresConfirmation: false,
                successCondition: "reminder is saved"
            )
        }

        if lower.contains("take a note") || lower.contains("create note") || lower.contains("new note") {
            return PipToolCall(
                thoughtSummary: "create note",
                action: .macCreateNote,
                args: ["text": goal],
                requiresConfirmation: false,
                successCondition: "note is created"
            )
        }

        return nil
    }

    private static func isRisky(goal: String) -> Bool {
        [
            "empty trash", "delete permanently", "buy ", "purchase", "send email",
            "send message", "post this", "change password", "security settings",
            "privacy settings", "terminal", "run command"
        ].contains { goal.contains($0) }
    }

    private static func extractSearch(goal: String) -> (site: String, query: String)? {
        let lower = goal.lowercased()
        let site: String
        if lower.contains("youtube") || lower.contains("you tube") {
            site = "youtube"
        } else if lower.contains("google") {
            site = "google"
        } else if lower.contains("search") || lower.contains("look up") {
            site = "web"
        } else {
            return nil
        }

        let patterns = [
            "search youtube for ", "search you tube for ", "go to youtube and search ",
            "open youtube and search ", "search google for ", "google ",
            "search for ", "search ", "look up "
        ]
        var query = lower
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                query = String(goal[range.upperBound...])
                break
            }
        }
        query = query
            .replacingOccurrences(of: "please", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : (site, query)
    }

    private static func extractAppOpen(goal: String) -> String? {
        let lower = goal.lowercased()
        guard lower.contains("open ") || lower.contains("launch ") else { return nil }
        let knownApps = ["safari", "chrome", "terminal", "xcode", "finder", "notes", "calendar", "reminders"]
        return knownApps.first { lower.contains($0) }
    }
}
