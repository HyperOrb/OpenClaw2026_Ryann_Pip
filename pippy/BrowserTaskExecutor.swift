//
//  BrowserTaskExecutor.swift
//  pippy
//
//  High-level browser tasks for Pip's visible operator mode.
//

import AppKit
import Foundation

@MainActor
final class BrowserTaskExecutor {
    private struct SearchableWebsite {
        let triggers: [String]
        let displayName: String
        let homeURL: URL
        let searchFieldKeywords: [String]
        let physicalSearchYOffset: CGFloat
        let makeSearchURL: (String) -> URL?
    }

    private let uiAutomationExecutor: UIAutomationExecutor
    private let maximumOperatorSteps = 6

    private let searchableWebsites: [SearchableWebsite] = [
        SearchableWebsite(
            triggers: ["youtube", "you tube", "yt"],
            displayName: "youtube",
            homeURL: URL(string: "https://www.youtube.com")!,
            searchFieldKeywords: ["search", "youtube"],
            physicalSearchYOffset: 105,
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)")
            }
        ),
        SearchableWebsite(
            triggers: ["google"],
            displayName: "google",
            homeURL: URL(string: "https://www.google.com")!,
            searchFieldKeywords: ["search", "google"],
            physicalSearchYOffset: 310,
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://www.google.com/search?q=\(encodedQuery)")
            }
        ),
        SearchableWebsite(
            triggers: ["github", "git hub"],
            displayName: "github",
            homeURL: URL(string: "https://github.com")!,
            searchFieldKeywords: ["search", "github"],
            physicalSearchYOffset: 82,
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://github.com/search?q=\(encodedQuery)&type=repositories")
            }
        ),
        SearchableWebsite(
            triggers: ["x", "twitter"],
            displayName: "x",
            homeURL: URL(string: "https://x.com")!,
            searchFieldKeywords: ["search", "x", "twitter"],
            physicalSearchYOffset: 105,
            makeSearchURL: { query in
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                return URL(string: "https://x.com/search?q=\(encodedQuery)&src=typed_query")
            }
        )
    ]

    init(uiAutomationExecutor: UIAutomationExecutor) {
        self.uiAutomationExecutor = uiAutomationExecutor
    }

    func executeMatchingBrowserTask(for transcript: String) async -> ToolExecutionResult? {
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

        return await searchWebsite(matchedWebsite, query: query)
    }

    private func searchWebsite(
        _ website: SearchableWebsite,
        query: String
    ) async -> ToolExecutionResult {
        guard let fallbackSearchURL = website.makeSearchURL(query) else {
            return ToolExecutionResult(
                success: false,
                actionDescription: "search \(website.displayName) for \(query)",
                observedState: "could not build a search url",
                needsConfirmation: false
            )
        }

        var completedOperatorSteps = 1
        uiAutomationExecutor.openURL(website.homeURL)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        completedOperatorSteps += 1
        let didUsePhysicalSearch = await uiAutomationExecutor.clickApproximateSearchAreaAndSubmit(
            query: query,
            verticalOffsetFromWindowTop: website.physicalSearchYOffset
        )

        if didUsePhysicalSearch {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let observation = uiAutomationExecutor.observeFocusedApp()
            return ToolExecutionResult(
                success: true,
                actionDescription: "search \(website.displayName) for \(query)",
                observedState: "operator loop \(completedOperatorSteps)/\(maximumOperatorSteps); moved the paw cursor, clicked \(website.displayName)'s search area, typed \(query), and pressed return; focused app is \(observation.appName), window is \(observation.focusedWindowTitle ?? "unknown")",
                needsConfirmation: false
            )
        }

        if uiAutomationExecutor.hasAccessibilityPermission {
            completedOperatorSteps += 1
            let didUseAccessibleSearchField = await uiAutomationExecutor.focusSearchFieldAndSubmit(
                query: query,
                keywords: website.searchFieldKeywords
            )

            if didUseAccessibleSearchField {
                try? await Task.sleep(nanoseconds: 900_000_000)
                let observation = uiAutomationExecutor.observeFocusedApp()
                return ToolExecutionResult(
                    success: true,
                    actionDescription: "search \(website.displayName) for \(query)",
                    observedState: "operator loop \(completedOperatorSteps)/\(maximumOperatorSteps); used accessibility to type into \(website.displayName); focused app is \(observation.appName), window is \(observation.focusedWindowTitle ?? "unknown")",
                    needsConfirmation: false
                )
            }
        }

        completedOperatorSteps += 1
        await uiAutomationExecutor.commandLTypeURLAndSubmitVisibly(fallbackSearchURL)
        try? await Task.sleep(nanoseconds: 700_000_000)
        return ToolExecutionResult(
            success: true,
            actionDescription: "search \(website.displayName) for \(query)",
            observedState: "operator loop \(completedOperatorSteps)/\(maximumOperatorSteps); Pip typed the direct search url into the browser after the search field path was unavailable",
            needsConfirmation: false
        )
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
