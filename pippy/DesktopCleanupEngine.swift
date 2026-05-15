//
//  DesktopCleanupEngine.swift
//  pippy
//
//  Plans and executes desktop organization tasks with verification.
//

import Foundation

struct DesktopCleanupEngine {
    private let fileManager = FileManager.default

    func proposeCleanupPlan() throws -> DesktopCleanupPlanProposal {
        let desktopURL = try desktopDirectoryURL()
        let desktopContents = try fileManager.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        )

        var actions: [TaskAction] = []
        var preview: [String] = []
        var foldersToCreate = Set<URL>()

        for itemURL in desktopContents {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            if values.isDirectory == true { continue }

            let targetFolderName = folderName(for: itemURL)
            let folderURL = desktopURL.appendingPathComponent(targetFolderName, isDirectory: true)
            foldersToCreate.insert(folderURL)

            let targetURL = uniqueTargetURL(
                for: itemURL,
                in: folderURL
            )
            actions.append(.moveItem(from: itemURL, to: targetURL))
            preview.append("\(itemURL.lastPathComponent) -> \(targetFolderName)/\(targetURL.lastPathComponent)")
        }

        for folderURL in foldersToCreate.sorted(by: { $0.path < $1.path }) {
            actions.insert(.createFolder(url: folderURL), at: 0)
        }

        let summary = actions.isEmpty
            ? "desktop is already organized"
            : "organize \(preview.count) files into \(foldersToCreate.count) folders"

        let plan = TaskPlan(
            id: UUID(),
            title: "Desktop Cleanup",
            summary: summary,
            riskLevel: preview.count > 5 ? .risky : .safe,
            actions: actions,
            createdAt: Date()
        )

        return DesktopCleanupPlanProposal(
            plan: plan,
            previewLines: Array(preview.prefix(12))
        )
    }

    func execute(proposal: DesktopCleanupPlanProposal) -> TaskExecutionResult {
        guard !proposal.plan.actions.isEmpty else {
            return TaskExecutionResult(
                success: true,
                completedActions: 0,
                failedActions: 0,
                verificationPassed: true,
                message: "desktop is already organized"
            )
        }

        var completedActions = 0
        var failedActions = 0

        for action in proposal.plan.actions {
            do {
                switch action {
                case .createFolder(let url):
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                case .moveItem(let from, let to):
                    try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: from.path) {
                        try fileManager.moveItem(at: from, to: to)
                    }
                case .generatePDF:
                    break
                }
                completedActions += 1
            } catch {
                failedActions += 1
            }
        }

        let verificationPassed = verify(proposal: proposal)
        let success = failedActions == 0 && verificationPassed
        let message = success
            ? "desktop cleanup completed and verified"
            : "desktop cleanup finished with \(failedActions) failed actions"

        return TaskExecutionResult(
            success: success,
            completedActions: completedActions,
            failedActions: failedActions,
            verificationPassed: verificationPassed,
            message: message
        )
    }

    private func verify(proposal: DesktopCleanupPlanProposal) -> Bool {
        for action in proposal.plan.actions {
            switch action {
            case .moveItem(_, let to):
                if !fileManager.fileExists(atPath: to.path) {
                    return false
                }
            case .createFolder(let url):
                var isDirectory: ObjCBool = false
                if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                    return false
                }
            case .generatePDF:
                continue
            }
        }
        return true
    }

    private func folderName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) { return "Images" }
        if ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) { return "Videos" }
        if ["mp3", "wav", "aiff", "m4a"].contains(ext) { return "Audio" }
        if ["pdf"].contains(ext) { return "PDFs" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "Archives" }
        if ["doc", "docx", "txt", "md", "rtf"].contains(ext) { return "Documents" }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return "Spreadsheets" }
        if ["ppt", "pptx", "key"].contains(ext) { return "Presentations" }
        if ["swift", "py", "js", "ts", "json", "yaml", "yml", "go", "rs", "java", "cpp", "c", "rb"].contains(ext) { return "Code" }
        return "Others"
    }

    private func desktopDirectoryURL() throws -> URL {
        guard let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "DesktopCleanupEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Desktop directory not found"])
        }
        return desktop
    }

    private func uniqueTargetURL(for sourceURL: URL, in folderURL: URL) -> URL {
        var candidateURL = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var counter = 1

        while fileManager.fileExists(atPath: candidateURL.path) {
            let fileName = ext.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(ext)"
            candidateURL = folderURL.appendingPathComponent(fileName)
            counter += 1
        }

        return candidateURL
    }
}
