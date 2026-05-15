//
//  ToolExecutionResult.swift
//  pippy
//
//  Structured local tool results for Pip's operator loop.
//

import Foundation

struct ToolExecutionResult {
    let success: Bool
    let actionDescription: String
    let observedState: String
    let needsConfirmation: Bool

    var agentLogLine: String {
        let status = success ? "succeeded" : "failed"
        let confirmationSuffix = needsConfirmation ? " confirmation needed." : ""
        return "tool: \(actionDescription) \(status). observed: \(observedState).\(confirmationSuffix)"
    }
}

enum PipToolAction: String, Codable {
    case finalAnswer = "final.answer"
    case askConfirmation = "safety.confirm"
    case browserOpen = "browser.open"
    case browserSearch = "browser.search"
    case browserSnapshot = "browser.snapshot"
    case browserClick = "browser.click"
    case browserFill = "browser.fill"
    case browserPress = "browser.press"
    case browserExtractPageText = "browser.extractPageText"
    case browserVerifyText = "browser.verifyText"
    case macOpenApp = "mac.openApp"
    case macOpenURL = "mac.openURL"
    case macCreateReminder = "mac.createReminder"
    case macCreateNote = "mac.createNote"
    case macCreateCalendarEvent = "mac.createCalendarEvent"
    case filesListDesktop = "files.listDesktop"
    case filesOrganizeDesktopPlan = "files.organizeDesktopPlan"
    case screenTutor = "screen.tutor"
}

struct PipToolCall: Codable {
    var thoughtSummary: String
    var action: PipToolAction
    var args: [String: String]
    var requiresConfirmation: Bool
    var successCondition: String

    enum CodingKeys: String, CodingKey {
        case thoughtSummary = "thought_summary"
        case action
        case args
        case requiresConfirmation = "requires_confirmation"
        case successCondition = "success_condition"
    }
}

struct PipStructuredToolResult: Codable {
    var success: Bool
    var action: PipToolAction
    var observation: String
    var url: String?
    var title: String?
    var text: String?
    var needsConfirmation: Bool
    var error: String?

    var agentLogLine: String {
        let status = success ? "verified" : "failed"
        let detail = error ?? observation
        return "\(action.rawValue): \(status) — \(detail)"
    }
}

struct PipAgentLoopResult {
    let handled: Bool
    let completed: Bool
    let summary: String
    let toolResults: [PipStructuredToolResult]
}

