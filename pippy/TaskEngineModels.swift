//
//  TaskEngineModels.swift
//  pippy
//
//  Structured models for advanced multi-step task execution.
//

import Foundation

enum TaskRiskLevel: String {
    case safe
    case risky
    case destructive
}

enum TaskAction {
    case createFolder(url: URL)
    case moveItem(from: URL, to: URL)
    case generatePDF(fileName: String)
}

struct TaskPlan {
    let id: UUID
    let title: String
    let summary: String
    let riskLevel: TaskRiskLevel
    let actions: [TaskAction]
    let createdAt: Date
}

struct TaskExecutionResult {
    let success: Bool
    let completedActions: Int
    let failedActions: Int
    let verificationPassed: Bool
    let message: String
}

struct DesktopCleanupPlanProposal {
    let plan: TaskPlan
    let previewLines: [String]
}

struct ResearchSource {
    let title: String
    let url: URL
    let snippet: String
}

struct ResearchReport {
    let title: String
    let query: String
    let generatedAt: Date
    let body: String
    let sources: [ResearchSource]
}

enum PendingRiskOperation {
    case desktopCleanup(plan: DesktopCleanupPlanProposal)
    case exportResearch(report: ResearchReport, defaultFileName: String)
}

struct PendingRiskConfirmation {
    let id: UUID
    let operation: PendingRiskOperation
    let createdAt: Date
    let cardID: UUID?
    let runID: UUID?
}

extension PendingRiskOperation {
    var summaryText: String {
        switch self {
        case .desktopCleanup(let proposal):
            return proposal.plan.summary
        case .exportResearch(_, let defaultFileName):
            return "export research report as \(defaultFileName)"
        }
    }
}
