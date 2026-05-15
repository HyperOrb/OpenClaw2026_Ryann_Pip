//
//  NativeToolExecutor.swift
//  pippy
//
//  Local native tool execution for quick "do this for me" actions.
//

import AppKit
import EventKit
import Foundation

@MainActor
final class NativeToolExecutor {
    private let uiAutomationExecutor = UIAutomationExecutor()
    private let browserTaskExecutor: BrowserTaskExecutor
    private let browserExecutor = BrowserActionExecutor()
    private let appExecutor = AppActionExecutor()
    private let productivityExecutor = ProductivityActionExecutor()
    private let researchExecutor = ResearchExportActionExecutor()
    private let websiteBuilderExecutor = LocalWebsiteBuilderExecutor()

    init() {
        self.browserTaskExecutor = BrowserTaskExecutor(uiAutomationExecutor: uiAutomationExecutor)
    }

    func executeMatchingTools(for transcript: String) async -> [String] {
        var results: [String] = []

        if let browserTaskResult = await browserTaskExecutor.executeMatchingBrowserTask(for: transcript) {
            results.append(browserTaskResult.agentLogLine)
            return results
        }

        results.append(contentsOf: browserExecutor.executeMatchingActions(transcript: transcript))
        results.append(contentsOf: appExecutor.executeMatchingActions(transcript: transcript))
        results.append(contentsOf: await productivityExecutor.executeMatchingActions(transcript: transcript))
        results.append(contentsOf: researchExecutor.executeMatchingActions(transcript: transcript))
        results.append(contentsOf: websiteBuilderExecutor.executeMatchingActions(transcript: transcript))

        return results
    }

    func executeStructuredTool(_ toolCall: PipToolCall) async -> PipStructuredToolResult {
        switch toolCall.action {
        case .macOpenApp:
            return openApp(named: toolCall.args["app"] ?? "")
        case .macOpenURL:
            return openURL(toolCall.args["url"] ?? toolCall.args["site"] ?? "")
        case .macCreateReminder:
            return await createReminder(from: toolCall.args["text"] ?? "")
        case .macCreateNote:
            return createNote(from: toolCall.args["text"] ?? "")
        case .macCreateCalendarEvent:
            return await createCalendarEvent(from: toolCall.args["text"] ?? "")
        case .filesListDesktop:
            return listDesktop()
        case .filesOrganizeDesktopPlan:
            return organizeDesktopPlan()
        default:
            return PipStructuredToolResult(
                success: false,
                action: toolCall.action,
                observation: "native tool cannot handle \(toolCall.action.rawValue)",
                url: nil,
                title: nil,
                text: nil,
                needsConfirmation: false,
                error: "unsupported native action"
            )
        }
    }

    func observeDesktop() -> String {
        let observation = uiAutomationExecutor.observeFocusedApp()
        return "focused app: \(observation.appName); window: \(observation.focusedWindowTitle ?? "unknown")"
    }

    private func openApp(named appName: String) -> PipStructuredToolResult {
        let normalized = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let appPaths: [String: String] = [
            "safari": "/Applications/Safari.app",
            "chrome": "/Applications/Google Chrome.app",
            "terminal": "/System/Applications/Utilities/Terminal.app",
            "xcode": "/Applications/Xcode.app",
            "finder": "/System/Library/CoreServices/Finder.app",
            "notes": "/System/Applications/Notes.app",
            "calendar": "/System/Applications/Calendar.app",
            "reminders": "/System/Applications/Reminders.app"
        ]
        guard let path = appPaths[normalized] else {
            return nativeResult(false, .macOpenApp, "unknown app \(appName)", error: "unknown app")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nativeResult(false, .macOpenApp, "\(normalized) is not installed", error: "app not found")
        }

        NSWorkspace.shared.open(url)
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased().contains(normalized) == true
        }
        return nativeResult(true, .macOpenApp, running ? "\(normalized) is running" : "requested \(normalized) to open")
    }

    private func openURL(_ value: String) -> PipStructuredToolResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nativeResult(false, .macOpenURL, "missing url", error: "missing url")
        }
        let urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: urlString) else {
            return nativeResult(false, .macOpenURL, "invalid url \(trimmed)", error: "invalid url")
        }
        NSWorkspace.shared.open(url)
        return PipStructuredToolResult(
            success: true,
            action: .macOpenURL,
            observation: "opened \(url.absoluteString)",
            url: url.absoluteString,
            title: nil,
            text: nil,
            needsConfirmation: false,
            error: nil
        )
    }

    private func createReminder(from text: String) async -> PipStructuredToolResult {
        let eventStore = EKEventStore()
        guard await requestAccess(to: .reminder, store: eventStore) else {
            return nativeResult(false, .macCreateReminder, "reminder permission not granted", error: "permission not granted")
        }

        let title = reminderTitle(from: text)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueDate = extractDetectedDate(from: text) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        do {
            try eventStore.save(reminder, commit: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
            return nativeResult(true, .macCreateReminder, "saved reminder \(title)")
        } catch {
            return nativeResult(false, .macCreateReminder, "failed to save reminder", error: error.localizedDescription)
        }
    }

    private func createNote(from text: String) -> PipStructuredToolResult {
        let body = noteBody(from: text)
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Notes"
            activate
            make new note with properties {body:"\(escapedBody)"}
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            return nativeResult(false, .macCreateNote, "failed to create note script", error: "script creation failed")
        }
        var errorDictionary: NSDictionary?
        script.executeAndReturnError(&errorDictionary)
        if let errorDictionary {
            return nativeResult(false, .macCreateNote, "failed to create note", error: errorDictionary.description)
        }
        return nativeResult(true, .macCreateNote, "created note")
    }

    private func createCalendarEvent(from text: String) async -> PipStructuredToolResult {
        let eventStore = EKEventStore()
        guard await requestAccess(to: .event, store: eventStore) else {
            return nativeResult(false, .macCreateCalendarEvent, "calendar permission not granted", error: "permission not granted")
        }
        let startDate = extractDetectedDate(from: text) ?? Date().addingTimeInterval(3600)
        let event = EKEvent(eventStore: eventStore)
        event.title = text.replacingOccurrences(of: "schedule", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(3600)
        event.calendar = eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent)
            return nativeResult(true, .macCreateCalendarEvent, "saved calendar event \(event.title ?? "new event")")
        } catch {
            return nativeResult(false, .macCreateCalendarEvent, "failed to save calendar event", error: error.localizedDescription)
        }
    }

    private func listDesktop() -> PipStructuredToolResult {
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        do {
            let items = try FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: [.isDirectoryKey])
            let text = items.prefix(80).map(\.lastPathComponent).joined(separator: "\n")
            return PipStructuredToolResult(
                success: true,
                action: .filesListDesktop,
                observation: "listed \(items.count) desktop items",
                url: desktopURL.path,
                title: "Desktop",
                text: text,
                needsConfirmation: false,
                error: nil
            )
        } catch {
            return nativeResult(false, .filesListDesktop, "failed to list desktop", error: error.localizedDescription)
        }
    }

    private func organizeDesktopPlan() -> PipStructuredToolResult {
        let proposalResult = listDesktop()
        guard proposalResult.success else { return proposalResult }
        return PipStructuredToolResult(
            success: true,
            action: .filesOrganizeDesktopPlan,
            observation: "i can organize the desktop by grouping screenshots, documents, images, archives, and folders, but i need confirmation before moving files.",
            url: proposalResult.url,
            title: "Desktop cleanup plan",
            text: proposalResult.text,
            needsConfirmation: true,
            error: nil
        )
    }

    private func nativeResult(
        _ success: Bool,
        _ action: PipToolAction,
        _ observation: String,
        error: String? = nil
    ) -> PipStructuredToolResult {
        PipStructuredToolResult(
            success: success,
            action: action,
            observation: observation,
            url: nil,
            title: nil,
            text: nil,
            needsConfirmation: false,
            error: error
        )
    }

    private func reminderTitle(from text: String) -> String {
        let lower = text.lowercased()
        for trigger in ["remind me to ", "set a reminder to ", "create a reminder to ", "add a reminder to "] {
            if let range = lower.range(of: trigger) {
                let suffix = String(text[range.upperBound...])
                let separators = [" tomorrow", " today", " at ", " on ", " by ", " for "]
                let cutIndex = separators
                    .compactMap { suffix.range(of: $0, options: .caseInsensitive)?.lowerBound }
                    .min() ?? suffix.endIndex
                let title = String(suffix[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? "new reminder" : title
            }
        }
        return "new reminder"
    }

    private func noteBody(from text: String) -> String {
        let lower = text.lowercased()
        for trigger in ["take a note ", "create note ", "new note "] {
            if let range = lower.range(of: trigger) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}

private struct LocalWebsiteBuilderExecutor {
    func executeMatchingActions(transcript: String) -> [String] {
        let lowercasedTranscript = transcript.lowercased()
        let isWebsiteBuildRequest = lowercasedTranscript.contains("website")
            && (lowercasedTranscript.contains("make")
                || lowercasedTranscript.contains("create")
                || lowercasedTranscript.contains("build"))
        let isGreetingRequest = lowercasedTranscript.contains("hey")
            || lowercasedTranscript.contains("hello")
            || lowercasedTranscript.contains("greet")
            || lowercasedTranscript.contains("saying")

        guard isWebsiteBuildRequest && isGreetingRequest else {
            return []
        }

        do {
            let ownerName = computerOwnerDisplayName()
            let websiteURL = try createGreetingWebsite(ownerName: ownerName)
            let openResult = openWebsiteInBrowser(websiteURL)
            return ["tool: \(openResult.actionDescription) greeting website for \(ownerName) at \(websiteURL.path)"]
        } catch {
            return ["tool: failed to create greeting website (\(error.localizedDescription))"]
        }
    }

    private func computerOwnerDisplayName() -> String {
        let fullUserName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullUserName.isEmpty {
            return fullUserName
        }

        let accountName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountName.isEmpty {
            return accountName
        }

        return ProcessInfo.processInfo.userName
    }

    private func createGreetingWebsite(ownerName: String) throws -> URL {
        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("Pip Generated Sites", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let websiteURL = outputDirectory.appendingPathComponent("hey-\(slugify(ownerName)).html")
        try greetingWebsiteHTML(ownerName: ownerName).write(to: websiteURL, atomically: true, encoding: .utf8)
        guard FileManager.default.fileExists(atPath: websiteURL.path) else {
            throw NSError(
                domain: "PipWebsiteBuilder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "website file was not created"]
            )
        }
        return websiteURL
    }

    private func openWebsiteInBrowser(_ websiteURL: URL) -> (didRequestBrowserOpen: Bool, actionDescription: String) {
        let browserCandidateURLs = [
            URL(fileURLWithPath: "/Applications/Safari.app"),
            URL(fileURLWithPath: "/Applications/Google Chrome.app")
        ]

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = true

        if let browserURL = browserCandidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(
                [websiteURL],
                withApplicationAt: browserURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    print("⚠️ Pip website browser open failed: \(error.localizedDescription)")
                    NSWorkspace.shared.activateFileViewerSelecting([websiteURL])
                }
            }
            return (true, "created and requested browser open for")
        }

        let didOpenDefaultApplication = NSWorkspace.shared.open(websiteURL)
        if didOpenDefaultApplication {
            NSWorkspace.shared.activateFileViewerSelecting([websiteURL])
            return (true, "created and requested default-app open for")
        }

        NSWorkspace.shared.activateFileViewerSelecting([websiteURL])
        return (false, "created but could not browser-open, revealed file for")
    }

    private func slugify(_ text: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(scalars)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "owner" : slug
    }

    private func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func greetingWebsiteHTML(ownerName: String) -> String {
        let safeOwnerName = escapedHTML(ownerName)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Hey \(safeOwnerName)</title>
          <style>
            :root {
              color-scheme: dark;
              --ink: #f7f1e8;
              --muted: rgba(247, 241, 232, 0.68);
              --line: rgba(247, 241, 232, 0.16);
              --rose: #ff7a90;
              --mint: #7ef0c1;
              --blue: #72b8ff;
              --bg: #101114;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              overflow: hidden;
              font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
              color: var(--ink);
              background:
                radial-gradient(circle at 18% 18%, rgba(255, 122, 144, 0.28), transparent 28rem),
                radial-gradient(circle at 84% 24%, rgba(126, 240, 193, 0.18), transparent 30rem),
                radial-gradient(circle at 55% 92%, rgba(114, 184, 255, 0.22), transparent 34rem),
                linear-gradient(135deg, #111217 0%, #17131b 48%, #0c1516 100%);
            }
            main {
              width: min(920px, calc(100vw - 40px));
              min-height: min(620px, calc(100vh - 40px));
              display: grid;
              align-content: center;
              gap: 34px;
              padding: clamp(28px, 6vw, 72px);
              border: 1px solid var(--line);
              border-radius: 28px;
              background: rgba(12, 13, 16, 0.58);
              box-shadow: 0 40px 120px rgba(0, 0, 0, 0.42), inset 0 1px 0 rgba(255, 255, 255, 0.08);
              backdrop-filter: blur(28px);
            }
            .eyebrow {
              width: fit-content;
              padding: 8px 12px;
              border: 1px solid var(--line);
              border-radius: 999px;
              color: var(--muted);
              font-size: 13px;
              letter-spacing: 0;
              background: rgba(255, 255, 255, 0.06);
            }
            h1 {
              margin: 0;
              max-width: 760px;
              font-size: clamp(52px, 10vw, 118px);
              line-height: 0.92;
              letter-spacing: 0;
            }
            h1 span {
              color: transparent;
              background: linear-gradient(100deg, var(--rose), #ffd38d 42%, var(--mint) 76%, var(--blue));
              -webkit-background-clip: text;
              background-clip: text;
            }
            p {
              margin: 0;
              max-width: 620px;
              color: var(--muted);
              font-size: clamp(18px, 2vw, 24px);
              line-height: 1.5;
            }
            .signature {
              display: flex;
              align-items: center;
              gap: 12px;
              color: rgba(247, 241, 232, 0.78);
              font-size: 14px;
            }
            .paw {
              width: 34px;
              height: 34px;
              display: grid;
              place-items: center;
              border-radius: 50%;
              background: linear-gradient(145deg, rgba(255, 122, 144, 0.95), rgba(126, 240, 193, 0.85));
              color: #151515;
              font-weight: 900;
            }
          </style>
        </head>
        <body>
          <main>
            <div class="eyebrow">made locally on this Mac</div>
            <h1>Hey, <span>\(safeOwnerName)</span>.</h1>
            <p>This little page was created by Pip after reading the computer owner's name from macOS and turning it into a warm welcome.</p>
            <div class="signature">
              <div class="paw">P</div>
              <div>Pip handled the file, the design, and opening it for you.</div>
            </div>
          </main>
        </body>
        </html>
        """
    }
}

private struct BrowserActionExecutor {
    private let websiteSearchTool = WebsiteSearchTool()
    private let urlTool = OpenURLTool()
    private let websiteTool = OpenWebsiteTool()
    private let searchTool = SafariSearchTool()

    func executeMatchingActions(transcript: String) -> [String] {
        var results: [String] = []
        if let result = websiteSearchTool.executeIfMatched(transcript: transcript) {
            results.append(result)
            return results
        }
        if let result = urlTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        if let result = websiteTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        if let result = searchTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        return results
    }
}

private struct AppActionExecutor {
    private let openAppTool = OpenAppTool()

    func executeMatchingActions(transcript: String) -> [String] {
        if let result = openAppTool.executeIfMatched(transcript: transcript) {
            return [result]
        }
        return []
    }
}

private struct ProductivityActionExecutor {
    private let reminderTool = ReminderTool()
    private let calendarTool = CalendarTool()
    private let noteTool = NotesTool()

    func executeMatchingActions(transcript: String) async -> [String] {
        var results: [String] = []
        if let result = await reminderTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        if let result = await calendarTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        if let result = noteTool.executeIfMatched(transcript: transcript) {
            results.append(result)
        }
        return results
    }
}

private struct ResearchExportActionExecutor {
    func executeMatchingActions(transcript: String) -> [String] {
        let lowercasedTranscript = transcript.lowercased()
        if lowercasedTranscript.contains("research")
            && lowercasedTranscript.contains("pdf") {
            return ["tool: advanced research/pdf workflow requested"]
        }
        return []
    }
}

private struct WebsiteSearchTool {
    private struct SearchableWebsite {
        let triggers: [String]
        let displayName: String
        let makeSearchURL: (String) -> URL?
    }

    private let searchableWebsites: [SearchableWebsite] = [
        SearchableWebsite(
            triggers: ["youtube", "you tube", "yt"],
            displayName: "youtube",
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)")
            }
        ),
        SearchableWebsite(
            triggers: ["google"],
            displayName: "google",
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://www.google.com/search?q=\(encodedQuery)")
            }
        ),
        SearchableWebsite(
            triggers: ["github", "git hub"],
            displayName: "github",
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://github.com/search?q=\(encodedQuery)&type=repositories")
            }
        ),
        SearchableWebsite(
            triggers: ["x", "twitter"],
            displayName: "x",
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://x.com/search?q=\(encodedQuery)&src=typed_query")
            }
        )
    ]

    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("search")
                || lowercasedTranscript.contains("look up")
                || lowercasedTranscript.contains("find") else {
            return nil
        }

        guard let matchedWebsite = searchableWebsites.first(where: { website in
            website.triggers.contains(where: { lowercasedTranscript.contains($0) })
        }) else {
            return nil
        }

        guard let query = extractSearchQuery(
            from: lowercasedTranscript,
            matchedWebsite: matchedWebsite
        ), !query.isEmpty else {
            return nil
        }

        guard let searchURL = matchedWebsite.makeSearchURL(query) else {
            return nil
        }

        NSWorkspace.shared.open(searchURL)
        return "tool: searched \(matchedWebsite.displayName) for \(query)"
    }

    private func extractSearchQuery(
        from lowercasedTranscript: String,
        matchedWebsite: SearchableWebsite
    ) -> String? {
        for websiteTrigger in matchedWebsite.triggers {
            let prefixPatterns = [
                "search \(websiteTrigger) for ",
                "search \(websiteTrigger) up for ",
                "search on \(websiteTrigger) for ",
                "search in \(websiteTrigger) for ",
                "search \(websiteTrigger) ",
                "open \(websiteTrigger) and search for ",
                "open \(websiteTrigger) and search up ",
                "open \(websiteTrigger) and look up ",
                "open \(websiteTrigger) and search ",
                "open up \(websiteTrigger) and search for ",
                "open up \(websiteTrigger) and search up ",
                "open up \(websiteTrigger) and look up ",
                "open up \(websiteTrigger) and search ",
                "go to \(websiteTrigger) and search for ",
                "go to \(websiteTrigger) and search up ",
                "go to \(websiteTrigger) and look up ",
                "go to \(websiteTrigger) and search ",
                "find \(websiteTrigger) videos about ",
                "find \(websiteTrigger) videos for "
            ]
            for prefixPattern in prefixPatterns {
                if let range = lowercasedTranscript.range(of: prefixPattern) {
                    return cleanSearchQuery(String(lowercasedTranscript[range.upperBound...]))
                }
            }

            let suffixPatterns = [
                " on \(websiteTrigger)",
                " in \(websiteTrigger)",
                " using \(websiteTrigger)"
            ]
            for suffixPattern in suffixPatterns {
                if let suffixRange = lowercasedTranscript.range(of: suffixPattern) {
                    let beforeWebsite = String(lowercasedTranscript[..<suffixRange.lowerBound])
                    if let query = extractQueryAfterSearchVerb(from: beforeWebsite) {
                        return cleanSearchQuery(query)
                    }
                }
            }
        }

        if let query = extractQueryAfterSearchVerb(from: lowercasedTranscript) {
            return cleanSearchQuery(removingWebsiteNames(from: query, matchedWebsite: matchedWebsite))
        }

        return nil
    }

    private func extractQueryAfterSearchVerb(from text: String) -> String? {
        let searchVerbPatterns = [
            "search up ",
            "search for ",
            "search ",
            "look up ",
            "find videos about ",
            "find videos for ",
            "find "
        ]

        for searchVerbPattern in searchVerbPatterns {
            if let range = text.range(of: searchVerbPattern) {
                return String(text[range.upperBound...])
            }
        }

        return nil
    }

    private func removingWebsiteNames(
        from query: String,
        matchedWebsite: SearchableWebsite
    ) -> String {
        var cleanedQuery = query
        for websiteTrigger in matchedWebsite.triggers {
            cleanedQuery = cleanedQuery.replacingOccurrences(of: websiteTrigger, with: " ")
        }
        return cleanedQuery
    }

    private func cleanSearchQuery(_ query: String) -> String {
        var cleanedQuery = query
            .replacingOccurrences(of: " for me", with: " ")
            .replacingOccurrences(of: " please", with: " ")
            .replacingOccurrences(of: " and open it", with: " ")
            .replacingOccurrences(of: " then open it", with: " ")
            .replacingOccurrences(of: " videos", with: " ")
            .replacingOccurrences(of: " video", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while cleanedQuery.contains("  ") {
            cleanedQuery = cleanedQuery.replacingOccurrences(of: "  ", with: " ")
        }

        return cleanedQuery
    }
}

private struct OpenURLTool {
    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("open ") else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let match = detector.firstMatch(in: transcript, range: range),
              let matchedURL = match.url else {
            return nil
        }
        NSWorkspace.shared.open(matchedURL)
        return "tool: open url \(matchedURL.absoluteString)"
    }
}

private struct SafariSearchTool {
    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        let triggers = ["search for ", "google ", "look up "]
        guard let trigger = triggers.first(where: { lowercasedTranscript.contains($0) }),
              let triggerRange = lowercasedTranscript.range(of: trigger) else {
            return nil
        }
        let query = String(lowercasedTranscript[triggerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let targetURLString = "https://www.google.com/search?q=\(encodedQuery)"
        guard let targetURL = URL(string: targetURLString) else { return nil }
        NSWorkspace.shared.open(targetURL)
        return "tool: search web for \(query)"
    }
}

private struct OpenWebsiteTool {
    private let knownWebsiteMap: [String: String] = [
        "youtube": "https://www.youtube.com",
        "nasa": "https://www.nasa.gov",
        "google": "https://www.google.com",
        "github": "https://github.com",
        "x": "https://x.com",
        "twitter": "https://x.com"
    ]

    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("open ") else { return nil }

        if let matchedWebsite = knownWebsiteMap.first(where: { lowercasedTranscript.contains($0.key) }) {
            guard let targetURL = URL(string: matchedWebsite.value) else { return nil }
            NSWorkspace.shared.open(targetURL)
            return "tool: open website \(matchedWebsite.key)"
        }

        let genericPattern = #"(?:open|go to)\s+([a-z0-9\-]+)\s+(?:website|site)"#
        guard let regex = try? NSRegularExpression(pattern: genericPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(lowercasedTranscript.startIndex..., in: lowercasedTranscript)
        guard let match = regex.firstMatch(in: lowercasedTranscript, options: [], range: range),
              let siteRange = Range(match.range(at: 1), in: lowercasedTranscript) else {
            return nil
        }
        let siteHost = String(lowercasedTranscript[siteRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !siteHost.isEmpty,
              let targetURL = URL(string: "https://www.\(siteHost).com") else {
            return nil
        }
        NSWorkspace.shared.open(targetURL)
        return "tool: open website \(siteHost)"
    }
}

private struct OpenAppTool {
    private let appLaunchCandidates: [(trigger: String, appPath: String)] = [
        ("safari", "/Applications/Safari.app"),
        ("chrome", "/Applications/Google Chrome.app"),
        ("terminal", "/System/Applications/Utilities/Terminal.app"),
        ("xcode", "/Applications/Xcode.app"),
        ("finder", "/System/Library/CoreServices/Finder.app"),
        ("notes", "/System/Applications/Notes.app"),
        ("calendar", "/System/Applications/Calendar.app"),
        ("reminders", "/System/Applications/Reminders.app")
    ]

    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("open ") || lowercasedTranscript.contains("launch ") else {
            return nil
        }
        guard let appLaunchCandidate = appLaunchCandidates.first(where: { lowercasedTranscript.contains($0.trigger) }) else {
            return nil
        }

        let appURL = URL(fileURLWithPath: appLaunchCandidate.appPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            return "tool: tried opening \(appLaunchCandidate.trigger), but the app was not found"
        }

        NSWorkspace.shared.open(appURL)
        return "tool: open app \(appLaunchCandidate.trigger)"
    }
}

private struct ReminderTool {
    func executeIfMatched(transcript: String) async -> String? {
        let lowercasedTranscript = transcript.lowercased()
        let isReminderIntent = lowercasedTranscript.contains("remind me")
            || lowercasedTranscript.contains("set a reminder")
            || lowercasedTranscript.contains("create a reminder")
            || lowercasedTranscript.contains("add a reminder")
        guard isReminderIntent else { return nil }
        let title = extractReminderTitle(from: transcript)
        guard !title.isEmpty else { return nil }

        let eventStore = EKEventStore()
        guard await requestAccess(to: .reminder, store: eventStore) else {
            return "tool: reminder permission not granted"
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        if let dueDate = extractDetectedDate(from: transcript) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        do {
            try eventStore.save(reminder, commit: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
            return "tool: created reminder \(title)"
        } catch {
            return "tool: failed to create reminder (\(error.localizedDescription))"
        }
    }

    private func extractReminderTitle(from transcript: String) -> String {
        let lowercasedTranscript = transcript.lowercased()
        let candidateTriggers = [
            "remind me to ",
            "set a reminder to ",
            "create a reminder to ",
            "add a reminder to ",
            "set a reminder ",
            "create a reminder ",
            "add a reminder "
        ]

        if let matchedTrigger = candidateTriggers.first(where: { lowercasedTranscript.contains($0) }),
           let triggerRange = lowercasedTranscript.range(of: matchedTrigger) {
            let suffix = String(transcript[triggerRange.upperBound...])
            let separators = [" tomorrow", " today", " at ", " on ", " by ", " for "]
            let cutIndex = separators
                .compactMap { suffix.range(of: $0, options: .caseInsensitive)?.lowerBound }
                .min() ?? suffix.endIndex
            let reminderTitle = String(suffix[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !reminderTitle.isEmpty {
                return reminderTitle
            }
        }

        if let detectedDate = extractDetectedDate(from: transcript) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "reminder \(formatter.string(from: detectedDate))"
        }

        return "new reminder"
    }
}

private struct CalendarTool {
    func executeIfMatched(transcript: String) async -> String? {
        let lowercasedTranscript = transcript.lowercased()
        let shouldCreateEvent = lowercasedTranscript.contains("schedule")
            || lowercasedTranscript.contains("calendar event")
            || lowercasedTranscript.contains("add event")
        guard shouldCreateEvent else { return nil }

        let eventStore = EKEventStore()
        guard await requestAccess(to: .event, store: eventStore) else {
            return "tool: calendar permission not granted"
        }

        let startDate = extractDetectedDate(from: transcript) ?? Date().addingTimeInterval(3600)
        let title = extractEventTitle(from: transcript)
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(3600)
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            return "tool: created calendar event \(title)"
        } catch {
            return "tool: failed to create calendar event (\(error.localizedDescription))"
        }
    }

    private func extractEventTitle(from transcript: String) -> String {
        let lowercasedTranscript = transcript.lowercased()
        if let range = lowercasedTranscript.range(of: "schedule ") {
            return String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = lowercasedTranscript.range(of: "add event ") {
            return String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "new event"
    }
}

private struct NotesTool {
    func executeIfMatched(transcript: String) -> String? {
        let lowercasedTranscript = transcript.lowercased()
        let shouldCreateNote = lowercasedTranscript.contains("take a note")
            || lowercasedTranscript.contains("create note")
            || lowercasedTranscript.contains("new note")
        guard shouldCreateNote else { return nil }

        let noteText = extractNoteBody(from: transcript)
        guard !noteText.isEmpty else { return nil }

        let escapedBody = noteText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Notes"
            activate
            make new note with properties {body:"\(escapedBody)"}
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return "tool: failed to create note script"
        }

        var errorDictionary: NSDictionary?
        script.executeAndReturnError(&errorDictionary)
        if let errorDictionary {
            return "tool: failed to create note (\(errorDictionary.description))"
        }
        return "tool: created note"
    }

    private func extractNoteBody(from transcript: String) -> String {
        let lowercasedTranscript = transcript.lowercased()
        let triggers = ["take a note ", "create note ", "new note "]
        for trigger in triggers {
            if let range = lowercasedTranscript.range(of: trigger) {
                return String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func requestAccess(to entityType: EKEntityType, store: EKEventStore) async -> Bool {
    await withCheckedContinuation { continuation in
        store.requestAccess(to: entityType) { granted, _ in
            continuation.resume(returning: granted)
        }
    }
}

private func extractDetectedDate(from transcript: String) -> Date? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
        return nil
    }
    let range = NSRange(transcript.startIndex..., in: transcript)
    return detector.firstMatch(in: transcript, range: range)?.date
}
