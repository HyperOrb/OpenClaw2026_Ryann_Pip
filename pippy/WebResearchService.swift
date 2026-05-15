//
//  WebResearchService.swift
//  pippy
//
//  Deterministic source gathering for research workflows.
//

import Foundation

final class WebResearchService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        self.session = URLSession(configuration: configuration)
    }

    func gatherSources(for query: String) async -> [ResearchSource] {
        let canonicalSources = sourceURLs(for: query)
        var results: [ResearchSource] = []

        for sourceURL in canonicalSources.prefix(5) {
            if let source = await fetchSource(from: sourceURL) {
                results.append(source)
            }
        }

        return results
    }

    private func sourceURLs(for query: String) -> [URL] {
        var urls: [URL] = [
            URL(string: "https://www.nasa.gov")!,
            URL(string: "https://www.spacex.com")!,
            URL(string: "https://www.esa.int")!,
            URL(string: "https://www.rocketlabusa.com")!,
            URL(string: "https://en.wikipedia.org/wiki/Rocket")!
        ]

        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let queryURL = URL(string: "https://duckduckgo.com/?q=\(encodedQuery)") {
            urls.insert(queryURL, at: 0)
        }

        return urls
    }

    private func fetchSource(from url: URL) async -> ResearchSource? {
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 PipResearchAgent", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            let plainText = stripHTML(html)
            let snippet = String(plainText.prefix(1400))
            let title = pageTitle(from: html) ?? url.host ?? "Source"
            return ResearchSource(title: title, url: url, snippet: snippet)
        } catch {
            return nil
        }
    }

    private func pageTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title>(.*?)</title>", options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return html[titleRange]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTML(_ html: String) -> String {
        let noScript = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        let noStyle = noScript.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        let noTags = noStyle.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsedWhitespace = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
