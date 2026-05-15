//
//  WakePhraseCoordinator.swift
//  pippy
//
//  Lightweight always-listening wake phrase detector. It continuously
//  transcribes microphone audio and emits utterances that begin with
//  "hey pip agent".
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class WakePhraseCoordinator: NSObject, ObservableObject {
    @Published private(set) var isListening: Bool = false

    var onWakePhraseUtterance: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var emitDebounceTask: Task<Void, Never>?
    private var latestTranscript: String = ""
    private var wakeDetected: Bool = false
    private var isEnabled: Bool = false

    private let wakePrefixes: [String] = [
        "hey pip agent",
        "hi pip agent"
    ]

    func setListeningEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            Task { [weak self] in
                await self?.requestPermissionsIfNeeded()
                await MainActor.run {
                    self?.startListeningIfNeeded()
                }
            }
        } else {
            stopListening()
        }
    }

    func stopListening() {
        restartTask?.cancel()
        restartTask = nil
        emitDebounceTask?.cancel()
        emitDebounceTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isListening = false
        latestTranscript = ""
        wakeDetected = false
    }

    private func startListeningIfNeeded() {
        guard isEnabled else { return }
        guard !isListening else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            scheduleRestart()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.handleRecognitionResult(result)
                }
                if error != nil {
                    self.scheduleRestart()
                }
            }
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        latestTranscript = result.bestTranscription.formattedString
        let normalizedTranscript = latestTranscript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if !wakeDetected, matchedWakePrefix(in: normalizedTranscript) != nil {
            wakeDetected = true
        }

        guard wakeDetected else { return }
        scheduleUtteranceEmit()
    }

    private func matchedWakePrefix(in text: String) -> String? {
        wakePrefixes.first(where: { text.contains($0) })
    }

    private func stripWakePrefix(from text: String) -> String {
        let normalizedText = text.lowercased()
        guard let wakePrefix = matchedWakePrefix(in: normalizedText),
              let wakeRange = normalizedText.range(of: wakePrefix) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suffix = normalizedText[wakeRange.upperBound...]
        return String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleUtteranceEmit() {
        emitDebounceTask?.cancel()
        let transcriptSnapshot = latestTranscript
        emitDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                guard let self else { return }
                let command = self.stripWakePrefix(from: transcriptSnapshot)
                if !command.isEmpty {
                    self.onWakePhraseUtterance?(command)
                }
                self.restartListeningSession()
            }
        }
    }

    private func restartListeningSession() {
        stopListening()
        guard isEnabled else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                self?.startListeningIfNeeded()
            }
        }
    }

    private func scheduleRestart() {
        stopListening()
        guard isEnabled else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                self?.startListeningIfNeeded()
            }
        }
    }

    private func requestPermissionsIfNeeded() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
}
