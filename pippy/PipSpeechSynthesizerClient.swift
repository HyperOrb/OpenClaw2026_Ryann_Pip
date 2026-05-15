//
//  PipSpeechSynthesizerClient.swift
//  pippy
//
//  Free local text-to-speech backed by macOS NSSpeechSynthesizer.
//

import AppKit
import Foundation

@MainActor
final class PipSpeechSynthesizerClient {
    private let synthesizer = NSSpeechSynthesizer()

    func speakText(_ text: String) async throws {
        stopPlayback()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        synthesizer.startSpeaking(trimmedText)
        print("🔊 Pip local speech: speaking \(trimmedText.count) characters")
    }

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
    }
}
