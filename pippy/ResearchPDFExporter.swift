//
//  ResearchPDFExporter.swift
//  pippy
//
//  Exports research reports to PDF.
//

import AppKit
import CoreFoundation
import CoreGraphics
import CoreText
import Foundation

final class ResearchPDFExporter {
    func export(report: ResearchReport, preferredFileName: String) throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let sanitizedName = sanitizeFileName(preferredFileName)
        let outputURL = documentsDirectory.appendingPathComponent("\(sanitizedName).pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ResearchPDFExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context"])
        }

        context.beginPDFPage(nil)

        let text = composeReportText(report: report)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 12, nil),
            .foregroundColor: CGColor(gray: 0.1, alpha: 1.0)
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let textRect = CGRect(x: 40, y: 40, width: 532, height: 712)
        let path = CGMutablePath()
        path.addRect(textRect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
        context.closePDF()

        return outputURL
    }

    private func composeReportText(report: ResearchReport) -> String {
        var lines: [String] = []
        lines.append(report.title)
        lines.append("")
        lines.append("Query: \(report.query)")
        lines.append("Generated: \(DateFormatter.localizedString(from: report.generatedAt, dateStyle: .medium, timeStyle: .short))")
        lines.append("")
        lines.append(report.body)
        lines.append("")
        lines.append("References")
        lines.append("")
        for (index, source) in report.sources.enumerated() {
            lines.append("[\(index + 1)] \(source.title) — \(source.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    private func sanitizeFileName(_ fileName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return String(fileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }
}
