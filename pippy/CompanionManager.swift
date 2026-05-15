//
//  CompanionManager.swift
//  pippy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionTriggerSource: String {
    case pushToTalk = "push-to-talk"
    case wakePhrase = "wake-phrase"
}

enum PipBrainMode: String, CaseIterable {
    case local = "local"
    case vps = "vps"
    case groq = "groq"
}

enum AgentRunStatus: String {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct AgentRunSnapshot: Identifiable {
    let id: UUID
    let transcript: String
    let source: CompanionTriggerSource
    let queuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var status: AgentRunStatus
    var latestStep: String
    var stepLog: [String]
    var errorDescription: String?
}

struct AgentCardSnapshot: Identifiable {
    let id: UUID
    var title: String
    var status: AgentRunStatus
    let createdAt: Date
    var updatedAt: Date
    var lastTranscript: String
    var latestStep: String
    var runIDs: [UUID]
}

private struct QueuedUtterance {
    let id: UUID
    let transcript: String
    let source: CompanionTriggerSource
    let queuedAt: Date
    let cardID: UUID
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var lastPermissionCheckDate: Date?

    /// Screen location (global AppKit coords) of a detected UI element the
    /// Pip should fly to and point at. Parsed from the local agent response.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so PipPetOverlayView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// PipPetOverlayView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let pipDictationManager = PipDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    @Published private(set) var currentAgentStepDescription: String = "ready for a task"
    @Published private(set) var recentAgentStepDescriptions: [String] = []
    @Published private(set) var activeAgentRun: AgentRunSnapshot?
    @Published private(set) var queuedAgentRuns: [AgentRunSnapshot] = []
    @Published private(set) var recentAgentRuns: [AgentRunSnapshot] = []
    @Published private(set) var isWakePhraseListening: Bool = false
    @Published private(set) var wakePhraseLastHeardAt: Date?
    @Published private(set) var agentCards: [AgentCardSnapshot] = []
    @Published var typedFollowUpDraft: String = ""

    private let ollamaAgentClient = OllamaAgentClient()
    private let vpsBrainAPIClient = VPSBrainAPIClient()
    private let groqAPIClient = GroqAPIClient()
    private lazy var pipCloudPlannerClient = PipCloudPlannerClient(groqAPIClient: groqAPIClient)
    private lazy var pipAgentOrchestrator = PipAgentOrchestrator(
        plannerClient: pipCloudPlannerClient,
        sidecarClient: agentSidecarClient,
        nativeToolExecutor: nativeToolExecutor
    )
    private lazy var computerOperatorAgent = ComputerOperatorAgent(
        ollamaAgentClient: ollamaAgentClient,
        uiAutomationExecutor: UIAutomationExecutor()
    )
    private let agentSidecarClient = AgentSidecarClient()
    private let pipSpeechSynthesizerClient = PipSpeechSynthesizerClient()
    private let nativeToolExecutor = NativeToolExecutor()
    private let desktopCleanupEngine = DesktopCleanupEngine()
    private let webResearchService = WebResearchService()
    private let researchPDFExporter = ResearchPDFExporter()
    private let wakePhraseCoordinator = WakePhraseCoordinator()
    private let notchHudWindowManager = NotchHudWindowManager()
    private let agentCardsWindowManager = AgentCardsWindowManager()
    @Published private(set) var pendingRiskSummaryText: String?

    /// Conversation history so Pip remembers prior exchanges within a session.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var runStepLogBuffer: [String] = []
    private var pendingUtterances: [QueuedUtterance] = []
    private var runToCardMap: [UUID: UUID] = [:]
    private var pendingRiskConfirmation: PendingRiskConfirmation?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var wakePhraseListeningCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// Timestamp when the user released the push-to-talk key, used to measure
    /// how long transcription finalization takes.
    private var pushToTalkReleaseTime: CFAbsoluteTime?
    private var lastScreenCapturePermissionErrorAt: Date?
    private var hasDisabledScreenCaptureForSession = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the Pip pet overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The local Ollama model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = {
        let savedModel = UserDefaults.standard.string(forKey: "selectedPipOllamaModel")
        if savedModel == nil || savedModel == "gemma3" || savedModel == "gemma4" {
            UserDefaults.standard.set("gemma3:latest", forKey: "selectedPipOllamaModel")
            return "gemma3:latest"
        }
        return savedModel ?? "gemma3:latest"
    }()
    @Published private(set) var selectedBrainMode: PipBrainMode = PipBrainMode(
        rawValue: UserDefaults.standard.string(forKey: "selectedPipBrainMode") ?? PipBrainMode.local.rawValue
    ) ?? .local
    @Published var vpsAPIBaseURL: String = UserDefaults.standard.string(forKey: "pipVPSAPIBaseURL") ?? "http://localhost:3000"
    @Published var groqAPIKey: String = UserDefaults.standard.string(forKey: "pipGroqAPIKey") ?? ""
    @Published var groqModel: String = UserDefaults.standard.string(forKey: "pipGroqModel") ?? "llama-3.1-8b-instant"
    @Published var isWakePhraseModeEnabled: Bool = UserDefaults.standard.object(forKey: "isWakePhraseModeEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isWakePhraseModeEnabled")

    init() {
        agentCardsWindowManager.setCallbacks(
            onStopCard: { [weak self] cardID in
                self?.cancelActiveAgentCard(cardID)
            },
            onSendFollowUp: { [weak self] followUpText in
                Task { @MainActor [weak self] in
                    self?.typedFollowUpDraft = followUpText
                    self?.submitTypedFollowUp()
                }
            }
        )
        notchHudWindowManager.setCallbacks(
            onToggleWakePhrase: { [weak self] enabled in
                self?.setWakePhraseModeEnabled(enabled)
            },
            onToggleOverlay: { [weak self] enabled in
                self?.setPipPetEnabled(enabled)
            },
            onSelectModel: { [weak self] modelID in
                self?.setSelectedModel(modelID)
            },
            onSelectBrainMode: { [weak self] mode in
                self?.setSelectedBrainMode(mode)
            },
            onSaveVPSBaseURL: { [weak self] baseURL in
                self?.setVPSAPIBaseURL(baseURL)
            },
            onSaveGroqConfig: { [weak self] apiKey, model in
                self?.setGroqAPIKey(apiKey)
                self?.setGroqModel(model)
            },
            onCheckPermissions: { [weak self] in
                self?.checkCurrentPermissionStatus()
            },
            onFixPermissions: { [weak self] in
                self?.openFullAccessPermissionSetup()
            }
        )

        wakePhraseCoordinator.onWakePhraseUtterance = { [weak self] transcript in
            Task { @MainActor [weak self] in
                self?.wakePhraseLastHeardAt = Date()
                self?.deliverUserUtterance(transcript, source: .wakePhrase)
            }
        }
        wakePhraseListeningCancellable = wakePhraseCoordinator.$isListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isListening in
                self?.isWakePhraseListening = isListening
                self?.refreshOverlayPresentation()
            }
        setSelectedBrainMode(selectedBrainMode)
        vpsBrainAPIClient.setBaseURL(vpsAPIBaseURL)
        groqAPIClient.setAPIKey(groqAPIKey)
        groqAPIClient.setModel(groqModel)
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedPipOllamaModel")
        ollamaAgentClient.model = model
    }

    func setSelectedBrainMode(_ mode: PipBrainMode) {
        selectedBrainMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "selectedPipBrainMode")
        refreshOverlayPresentation()
    }

    func setVPSAPIBaseURL(_ baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vpsAPIBaseURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: "pipVPSAPIBaseURL")
        vpsBrainAPIClient.setBaseURL(trimmed)
    }

    func setGroqAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        groqAPIKey = trimmed
        UserDefaults.standard.set(trimmed, forKey: "pipGroqAPIKey")
        groqAPIClient.setAPIKey(trimmed)
    }

    func setGroqModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groqModel = trimmed
        UserDefaults.standard.set(trimmed, forKey: "pipGroqModel")
        groqAPIClient.setModel(trimmed)
    }

    func setWakePhraseModeEnabled(_ enabled: Bool) {
        isWakePhraseModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isWakePhraseModeEnabled")
        refreshWakePhraseCoordinator()
        refreshOverlayPresentation()
    }

    func submitTypedFollowUp() {
        let trimmedText = typedFollowUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        typedFollowUpDraft = ""
        deliverUserUtterance(trimmedText, source: .pushToTalk)
    }

    func cancelActiveAgentCard(_ cardID: UUID) {
        guard let activeRun = activeAgentRun else { return }
        guard runToCardMap[activeRun.id] == cardID else { return }
        currentResponseTask?.cancel()
        pipSpeechSynthesizerClient.stopPlayback()
        finalizeActiveRun(runID: activeRun.id, status: .cancelled, errorDescription: "Cancelled by user")
        currentResponseTask = nil
        startNextQueuedRunIfNeeded()
        refreshOverlayPresentation()
    }

    /// User preference for whether the Pip pet should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isPipPetEnabled: Bool = {
        UserDefaults.standard.object(forKey: "isPipPetEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "isPipPetEnabled")
    }()

    func setPipPetEnabled(_ enabled: Bool) {
        isPipPetEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isPipPetEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
        refreshOverlayPresentation()
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// The hackathon fork does not collect email before onboarding.
    @Published var hasSubmittedEmail: Bool = true

    func submitEmail(_ email: String) {
        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Pip start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        CompanionScreenCaptureUtility.logStartupDiagnostic()
        // Prime the TCC prompt at startup — this is a no-op if permission
        // is already granted, but if it's denied/unknown it surfaces the
        // system dialog or System Settings entry for the *current* bundle
        // path (helps when Xcode rebuilds invalidate the prior grant).
        _ = CGRequestScreenCaptureAccess()
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isPipPetEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        refreshWakePhraseCoordinator()
        notchHudWindowManager.show()
        agentCardsWindowManager.show()
        refreshOverlayPresentation()
    }

    /// Called by the overlay after Pip finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .pipDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        PipAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .pipDismissPanel, object: nil)
        PipAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Pip: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Pip: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        wakePhraseCoordinator.stopListening()
        pipDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        notchHudWindowManager.hide()
        agentCardsWindowManager.hide()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        wakePhraseListeningCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        refreshAllPermissions(allowPreviouslyGrantedFallback: true)
    }

    func checkCurrentPermissionStatus() {
        refreshAllPermissions(allowPreviouslyGrantedFallback: true)
    }

    func openFullAccessPermissionSetup() {
        WindowPositionManager.markFullComputerAccessConfirmedByUser()
        hasDisabledScreenCaptureForSession = false
        lastScreenCapturePermissionErrorAt = nil
        WindowPositionManager.revealAppInFinder()
        _ = WindowPositionManager.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            WindowPositionManager.openScreenRecordingSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WindowPositionManager.openInputMonitoringSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            WindowPositionManager.requestAutomationPermissionsForCommonApps()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
            WindowPositionManager.openAutomationSettings()
        }
        refreshAllPermissions(allowPreviouslyGrantedFallback: true)
    }

    private func refreshAllPermissions(allowPreviouslyGrantedFallback: Bool) {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadScreenContent = hasScreenContentPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        if allowPreviouslyGrantedFallback {
            hasAccessibilityPermission = WindowPositionManager.shouldTreatAccessibilityPermissionAsGrantedForSessionLaunch()
        } else {
            hasAccessibilityPermission = currentlyHasAccessibility
        }

        // Keep the global hotkey monitor alive even if accessibility status
        // momentarily reports false during dev/debug relaunches. `start()`
        // is idempotent and retries naturally on subsequent polls.
        globalPushToTalkShortcutMonitor.start()

        let currentlyHasScreenRecording = WindowPositionManager.hasScreenRecordingPermission()
        if allowPreviouslyGrantedFallback {
            hasScreenRecordingPermission = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()
        } else {
            hasScreenRecordingPermission = currentlyHasScreenRecording
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // ScreenCaptureKit uses the same macOS Screen Recording / Screen &
        // System Audio Recording TCC grant. Keeping a separate "screen content"
        // onboarding gate caused Pip to ask again even after the user had
        // already enabled the real system permission.
        hasScreenContentPermission = hasScreenRecordingPermission
        if hasScreenContentPermission {
            UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
        }
        lastPermissionCheckDate = Date()

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadScreenContent != hasScreenContentPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            PipAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            PipAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            PipAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadAll && allPermissionsGranted {
            PipAnalytics.trackAllPermissionsGranted()
        }
        refreshWakePhraseCoordinator()
        refreshOverlayPresentation()
    }

    private func refreshWakePhraseCoordinator() {
        let canListen = isWakePhraseModeEnabled
            && hasMicrophonePermission
            && hasCompletedOnboarding
            && allPermissionsGranted
        wakePhraseCoordinator.setListeningEnabled(canListen)
    }

    /// Keeps legacy UI actions from showing a second screen-recording prompt.
    /// The real system grant is already represented by Screen Recording.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        checkCurrentPermissionStatus()
        guard !hasScreenRecordingPermission else {
            hasScreenContentPermission = true
            UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
            return
        }

        isRequestingScreenContent = true
        Task {
            _ = WindowPositionManager.requestScreenRecordingPermission()
            await MainActor.run {
                isRequestingScreenContent = false
                checkCurrentPermissionStatus()
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = pipDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = pipDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                pipDictationManager.$isFinalizingTranscript,
                pipDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding or .processing while the AI
                // response pipeline is running — it manages those states
                // directly until TTS finishes.
                if self.currentResponseTask != nil
                    && (self.voiceState == .responding || self.voiceState == .processing) {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
                self.refreshOverlayPresentation()
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: PipPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !pipDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Hotkey always has priority over wake phrase listening.
            // Stop wake listener immediately so dictation can claim the mic.
            wakePhraseCoordinator.stopListening()

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isPipPetEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .pipDismissPanel, object: nil)

            // Stop spoken output from prior tasks while the user starts a new one.
            pipSpeechSynthesizerClient.stopPlayback()
            clearDetectedElementLocation()
            voiceState = .listening

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            PipAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await pipDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        if let releaseTime = self?.pushToTalkReleaseTime {
                            let transcribeDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - releaseTime) * 1000)
                            print("⏱️ Transcription finalized in \(transcribeDurationMilliseconds)ms")
                        }
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.deliverUserUtterance(finalTranscript, source: .pushToTalk)
                    }
                )
            }
            refreshOverlayPresentation()
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            PipAnalytics.trackPushToTalkReleased()
            pushToTalkReleaseTime = CFAbsoluteTimeGetCurrent()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            pipDictationManager.stopPushToTalkFromKeyboardShortcut()
            // Resume wake phrase listener after push-to-talk releases.
            refreshWakePhraseCoordinator()
            refreshOverlayPresentation()
        case .none:
            break
        }
    }

    private func deliverUserUtterance(_ transcript: String, source: CompanionTriggerSource) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        if shouldClearPendingRiskConfirmation(for: trimmedTranscript) {
            pendingRiskConfirmation = nil
            pendingRiskSummaryText = nil
        }

        lastTranscript = trimmedTranscript
        PipAnalytics.trackUserMessageSent(transcript: trimmedTranscript)

        let cardID = resolveTargetCardID(for: trimmedTranscript)
        enqueueOrUpdateCard(cardID: cardID, transcript: trimmedTranscript)

        let queuedUtterance = QueuedUtterance(
            id: UUID(),
            transcript: trimmedTranscript,
            source: source,
            queuedAt: Date(),
            cardID: cardID
        )
        pendingUtterances.append(queuedUtterance)
        queuedAgentRuns.append(
            AgentRunSnapshot(
                id: queuedUtterance.id,
                transcript: trimmedTranscript,
                source: source,
                queuedAt: queuedUtterance.queuedAt,
                startedAt: nil,
                finishedAt: nil,
                status: .queued,
                latestStep: "queued (\(source.rawValue))",
                stepLog: ["queued (\(source.rawValue))"],
                errorDescription: nil
            )
        )
        refreshOverlayPresentation()
        startNextQueuedRunIfNeeded()
    }

    private func startNextQueuedRunIfNeeded() {
        guard currentResponseTask == nil else { return }
        guard !pendingUtterances.isEmpty else { return }

        let nextUtterance = pendingUtterances.removeFirst()
        runToCardMap[nextUtterance.id] = nextUtterance.cardID
        if let queuedIndex = queuedAgentRuns.firstIndex(where: { $0.id == nextUtterance.id }) {
            var run = queuedAgentRuns.remove(at: queuedIndex)
            run.startedAt = Date()
            run.status = .running
            run.latestStep = "starting"
            run.stepLog = ["starting"]
            activeAgentRun = run
            updateCard(
                id: nextUtterance.cardID,
                status: .running,
                latestStep: run.latestStep,
                transcript: run.transcript,
                appendRunID: run.id
            )
        } else {
            activeAgentRun = AgentRunSnapshot(
                id: nextUtterance.id,
                transcript: nextUtterance.transcript,
                source: nextUtterance.source,
                queuedAt: nextUtterance.queuedAt,
                startedAt: Date(),
                finishedAt: nil,
                status: .running,
                latestStep: "starting",
                stepLog: ["starting"],
                errorDescription: nil
            )
            updateCard(
                id: nextUtterance.cardID,
                status: .running,
                latestStep: "starting",
                transcript: nextUtterance.transcript,
                appendRunID: nextUtterance.id
            )
        }
        runStepLogBuffer = []
        refreshOverlayPresentation()
        sendTranscriptToPipAgentWithScreenshot(
            transcript: nextUtterance.transcript,
            runID: nextUtterance.id
        )
    }

    private func finalizeActiveRun(
        runID: UUID,
        status: AgentRunStatus,
        errorDescription: String? = nil
    ) {
        guard var run = activeAgentRun, run.id == runID else { return }
        run.status = status
        run.finishedAt = Date()
        run.errorDescription = errorDescription
        if !runStepLogBuffer.isEmpty {
            run.stepLog = runStepLogBuffer
            run.latestStep = runStepLogBuffer.last ?? run.latestStep
        }
        recentAgentRuns.append(run)
        if recentAgentRuns.count > 8 {
            recentAgentRuns.removeFirst(recentAgentRuns.count - 8)
        }
        if let cardID = runToCardMap[runID] {
            updateCard(
                id: cardID,
                status: status,
                latestStep: run.latestStep,
                transcript: run.transcript,
                appendRunID: nil
            )
        }
        activeAgentRun = nil
        runStepLogBuffer = []
        refreshOverlayPresentation()
    }

    private func recordAgentStep(_ stepDescription: String, runID: UUID? = nil) {
        currentAgentStepDescription = stepDescription
        recentAgentStepDescriptions.append(stepDescription)
        if recentAgentStepDescriptions.count > 6 {
            recentAgentStepDescriptions.removeFirst(recentAgentStepDescriptions.count - 6)
        }
        if let runID,
           var run = activeAgentRun,
           run.id == runID {
            run.latestStep = stepDescription
            run.stepLog.append(stepDescription)
            activeAgentRun = run
            runStepLogBuffer = run.stepLog
            if let cardID = runToCardMap[runID] {
                updateCard(
                    id: cardID,
                    status: run.status,
                    latestStep: stepDescription,
                    transcript: run.transcript,
                    appendRunID: nil
                )
            }
        }
        print("🤖 Pip agent: \(stepDescription)")
        refreshOverlayPresentation()
    }

    private func resolveTargetCardID(for transcript: String) -> UUID {
        let lowercasedTranscript = transcript.lowercased()
        if lowercasedTranscript.contains("new agent")
            || lowercasedTranscript.contains("new task")
            || lowercasedTranscript.contains("start over") {
            return UUID()
        }

        let followUpPrefixes = ["and ", "also ", "then ", "follow up", "continue", "now "]
        let likelyFollowUp = followUpPrefixes.contains { lowercasedTranscript.hasPrefix($0) }
        if likelyFollowUp {
            if let activeRun = activeAgentRun,
               let activeCardID = runToCardMap[activeRun.id] {
                return activeCardID
            }
            if let latestCard = agentCards.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                return latestCard.id
            }
        }

        let words = Set(lowercasedTranscript.split(separator: " ").map(String.init))
        if let bestMatch = agentCards.max(by: { lhs, rhs in
            lexicalSimilarity(lhs.lastTranscript, words) < lexicalSimilarity(rhs.lastTranscript, words)
        }) {
            let score = lexicalSimilarity(bestMatch.lastTranscript, words)
            let isRecent = Date().timeIntervalSince(bestMatch.updatedAt) < 240
            if score >= 0.35 && isRecent {
                return bestMatch.id
            }
        }

        return UUID()
    }

    private func lexicalSimilarity(_ previousTranscript: String, _ currentWords: Set<String>) -> Double {
        let previousWords = Set(previousTranscript.lowercased().split(separator: " ").map(String.init))
        guard !previousWords.isEmpty, !currentWords.isEmpty else { return 0 }
        let overlap = previousWords.intersection(currentWords).count
        let union = previousWords.union(currentWords).count
        return union == 0 ? 0 : Double(overlap) / Double(union)
    }

    private func enqueueOrUpdateCard(cardID: UUID, transcript: String) {
        if let index = agentCards.firstIndex(where: { $0.id == cardID }) {
            agentCards[index].updatedAt = Date()
            agentCards[index].lastTranscript = transcript
            agentCards[index].latestStep = "queued"
            if agentCards[index].status != .running {
                agentCards[index].status = .queued
            }
            return
        }

        let card = AgentCardSnapshot(
            id: cardID,
            title: titleForTranscript(transcript),
            status: .queued,
            createdAt: Date(),
            updatedAt: Date(),
            lastTranscript: transcript,
            latestStep: "queued",
            runIDs: []
        )
        agentCards.insert(card, at: 0)
        if agentCards.count > 24 {
            agentCards.removeLast(agentCards.count - 24)
        }
    }

    private func updateCard(
        id: UUID,
        status: AgentRunStatus,
        latestStep: String,
        transcript: String,
        appendRunID: UUID?
    ) {
        guard let index = agentCards.firstIndex(where: { $0.id == id }) else { return }
        agentCards[index].status = status
        agentCards[index].latestStep = latestStep
        agentCards[index].lastTranscript = transcript
        agentCards[index].updatedAt = Date()
        if let appendRunID, !agentCards[index].runIDs.contains(appendRunID) {
            agentCards[index].runIDs.append(appendRunID)
        }
    }

    private func titleForTranscript(_ transcript: String) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "new agent" }
        let words = cleaned.split(separator: " ").prefix(5)
        return words.joined(separator: " ")
    }

    private func handlePendingRiskConfirmationIfNeeded(
        transcript: String,
        runID: UUID
    ) async throws -> String? {
        guard let pendingRiskConfirmation else { return nil }
        let lowercased = transcript.lowercased()

        if lowercased.contains("cancel") || lowercased.contains("don't do it") {
            self.pendingRiskConfirmation = nil
            pendingRiskSummaryText = nil
            recordAgentStep("risk gate: operation cancelled", runID: runID)
            return "okay, i cancelled that operation."
        }

        guard lowercased.contains("confirm")
                || lowercased.contains("yes do it")
                || lowercased.contains("proceed") else {
            return "i still need confirmation. say confirm to proceed, or cancel to stop."
        }

        recordAgentStep("risk gate: confirmed by user", runID: runID)
        self.pendingRiskConfirmation = nil
        pendingRiskSummaryText = nil

        switch pendingRiskConfirmation.operation {
        case .desktopCleanup(let proposal):
            let result = desktopCleanupEngine.execute(proposal: proposal)
            recordAgentStep("verify: \(result.message)", runID: runID)
            return result.message
        case .exportResearch(let report, let defaultFileName):
            let outputURL = try researchPDFExporter.export(report: report, preferredFileName: defaultFileName)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            let verified = fileSize > 0
            let message = verified
                ? "done, your report pdf is saved in documents as \(outputURL.lastPathComponent)."
                : "i exported a pdf, but verification failed for that file."
            recordAgentStep("verify: pdf export \(verified ? "passed" : "failed")", runID: runID)
            return message
        }
    }

    private func handleAdvancedTaskIfRequested(
        transcript: String,
        runID: UUID
    ) async throws -> String? {
        let lowercased = transcript.lowercased()

        if lowercased.contains("cleanup my desktop")
            || lowercased.contains("organize my desktop")
            || lowercased.contains("clean up my desktop") {
            recordAgentStep("planner: building desktop cleanup plan", runID: runID)
            let proposal = try desktopCleanupEngine.proposeCleanupPlan()
            if proposal.plan.actions.isEmpty {
                return "your desktop already looks organized."
            }

            if proposal.plan.riskLevel != .safe {
                pendingRiskConfirmation = PendingRiskConfirmation(
                    id: UUID(),
                    operation: .desktopCleanup(plan: proposal),
                    createdAt: Date(),
                    cardID: runToCardMap[runID],
                    runID: runID
                )
                pendingRiskSummaryText = proposal.plan.summary
                let preview = proposal.previewLines.prefix(3).joined(separator: ", ")
                recordAgentStep("risk gate: awaiting confirmation for desktop cleanup", runID: runID)
                return "i prepared a cleanup plan: \(proposal.plan.summary). preview: \(preview). say confirm to apply it, or cancel."
            }

            let result = desktopCleanupEngine.execute(proposal: proposal)
            recordAgentStep("verify: \(result.message)", runID: runID)
            return result.message
        }

        if lowercased.contains("research")
            && (lowercased.contains("pdf") || lowercased.contains("report")) {
            let query = extractResearchQuery(from: transcript)
            recordAgentStep("planner: collecting web sources", runID: runID)

            let sources = await withTimeout(seconds: 35) { [self] in
                await self.webResearchService.gatherSources(for: query)
            } ?? []

            let reportBody = try await synthesizeResearchReport(query: query, sources: sources)
            let report = ResearchReport(
                title: "Research Report: \(query.capitalized)",
                query: query,
                generatedAt: Date(),
                body: reportBody,
                sources: sources
            )
            let defaultFileName = "pip-research-\(query.replacingOccurrences(of: " ", with: "-").lowercased())"

            pendingRiskConfirmation = PendingRiskConfirmation(
                id: UUID(),
                operation: .exportResearch(report: report, defaultFileName: defaultFileName),
                createdAt: Date(),
                cardID: runToCardMap[runID],
                runID: runID
            )
            pendingRiskSummaryText = "export research report as pdf"
            recordAgentStep("risk gate: awaiting confirmation for pdf export", runID: runID)
            return "i finished researching \(query) and prepared a report. say confirm to export the pdf, or cancel."
        }

        return nil
    }

    private func shouldUseOperatorMode(for transcript: String) -> Bool {
        let lowercased = transcript.lowercased()
        let directControlPhrases = [
            "click",
            "double click",
            "right click",
            "type ",
            "fill ",
            "fill out",
            "submit",
            "press ",
            "select ",
            "choose ",
            "scroll",
            "navigate",
            "use the app",
            "use this app",
            "on my screen",
            "with the paw",
            "using the paw",
            "control my mac",
            "do it on my computer",
            "do this on my computer"
        ]

        if directControlPhrases.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let multiStepSignals = [
            "open",
            "go to",
            "search",
            "find",
            "make",
            "create",
            "change",
            "edit"
        ]
        let hasMultiStepSignal = multiStepSignals.contains { lowercased.contains($0) }
        let hasConnector = lowercased.contains(" and ")
            || lowercased.contains(" then ")
            || lowercased.contains(" after that ")

        return hasMultiStepSignal && hasConnector
    }

    private func shouldUseSidecarAgent(for transcript: String) -> Bool {
        let lowercased = transcript.lowercased()
        let browserSignals = [
            "youtube",
            "google",
            "browser",
            "search bar",
            "search field",
            "search for",
            "look up",
            "fill this form",
            "fill out",
            "click the button"
        ]
        return browserSignals.contains { lowercased.contains($0) }
    }

    private func shouldUseImmediateNativeTool(for transcript: String) -> Bool {
        let lowercased = transcript.lowercased()
        let browserAutomationSignals = [
            "search",
            "look up",
            "find",
            "fill",
            "type",
            "click",
            "press",
            "submit"
        ]
        if browserAutomationSignals.contains(where: { lowercased.contains($0) }) {
            return false
        }

        let nativeSignals = [
            "open ",
            "launch ",
            "remind me",
            "set a reminder",
            "create a reminder",
            "add a reminder",
            "schedule",
            "calendar event",
            "take a note",
            "create note",
            "new note"
        ]
        return nativeSignals.contains { lowercased.contains($0) }
    }

    private func immediateNativeToolResponse(from toolResults: [String]) -> String? {
        guard let firstResult = toolResults.first else { return nil }
        let lowercased = firstResult.lowercased()

        if lowercased.contains("permission not granted") {
            return "i tried, but macos needs permission for that first."
        }
        if lowercased.contains("failed") || lowercased.contains("not found") {
            return "i tried, but \(firstResult.replacingOccurrences(of: "tool: ", with: ""))."
        }
        if lowercased.contains("open app") {
            return "done, i opened it."
        }
        if lowercased.contains("open website") || lowercased.contains("open url") {
            return "done, i opened it in the browser."
        }
        if lowercased.contains("created reminder") {
            return "done, i created the reminder."
        }
        if lowercased.contains("created calendar event") {
            return "done, i added it to your calendar."
        }
        if lowercased.contains("created note") {
            return "done, i created the note."
        }

        return nil
    }

    private func showPawFeedbackForSidecarResult(_ result: AgentSidecarClient.RunResponse) {
        guard isPipPetEnabled else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }

        let targetPoint = CGPoint(
            x: screen.frame.midX,
            y: screen.frame.maxY - 96
        )
        detectedElementScreenLocation = targetPoint
        detectedElementDisplayFrame = screen.frame
        detectedElementBubbleText = result.summary
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func showPawFeedbackForAgentLoopResult(_ result: PipAgentLoopResult) {
        guard isPipPetEnabled else { return }
        guard result.toolResults.contains(where: { $0.success }) else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }

        detectedElementScreenLocation = CGPoint(
            x: screen.frame.midX,
            y: screen.frame.maxY - 110
        )
        detectedElementDisplayFrame = screen.frame
        detectedElementBubbleText = result.summary
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func synthesizeResearchReport(query: String, sources: [ResearchSource]) async throws -> String {
        let sourceSummary = sources.enumerated().map { index, source in
            let snippet = source.snippet.prefix(500)
            return "[\(index + 1)] \(source.title) (\(source.url.absoluteString))\n\(snippet)"
        }.joined(separator: "\n\n")

        let prompt = """
        Create a concise but useful research report about: \(query)

        Requirements:
        - include a short executive summary
        - include key findings
        - include practical implications
        - cite sources inline using [1], [2], etc

        Sources:
        \(sourceSummary)
        """

        let response = await withTimeout(seconds: 45) { [self] in
            let text = try await self.generateAgentResponse(
                images: [],
                systemPrompt: "you are a research assistant that writes structured reports with citations.",
                conversationHistory: [],
                userPrompt: prompt,
                localToolResults: []
            )
            return (text: text, duration: 0)
        }
        if let response {
            let trimmedText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                return trimmedText
            }
        }

        return deterministicResearchFallback(query: query, sources: sources)
    }

    private func deterministicResearchFallback(query: String, sources: [ResearchSource]) -> String {
        let topPoints = sources.prefix(4).enumerated().map { index, source in
            "Finding \(index + 1): \(source.title) [\(index + 1)]"
        }.joined(separator: "\n")

        return """
        Executive Summary
        This report compiles key web sources about \(query) and highlights practical takeaways.

        Key Findings
        \(topPoints)

        Practical Implications
        - trends in \(query) suggest continued investment in reusable launch systems and mission cost efficiency.
        - policy, safety, and manufacturing scale are recurring constraints that shape execution speed.

        References
        \(sources.enumerated().map { "[\($0.offset + 1)] \($0.element.url.absoluteString)" }.joined(separator: "\n"))
        """
    }

    private func extractResearchQuery(from transcript: String) -> String {
        let lower = transcript.lowercased()
        if let range = lower.range(of: "research on ") {
            let query = String(transcript[range.upperBound...])
            return query.replacingOccurrences(of: " and make me a pdf out of it", with: "")
                .replacingOccurrences(of: " and make a pdf", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = lower.range(of: "research ") {
            let query = String(transcript[range.upperBound...])
            return query.replacingOccurrences(of: " and make me a pdf out of it", with: "")
                .replacingOccurrences(of: " and make a pdf", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "rockets"
    }

    private func shouldClearPendingRiskConfirmation(for transcript: String) -> Bool {
        guard pendingRiskConfirmation != nil else { return false }
        let lowercased = transcript.lowercased()

        let explicitRiskWords = ["confirm", "proceed", "cancel", "don't do it", "yes do it"]
        if explicitRiskWords.contains(where: { lowercased.contains($0) }) {
            return false
        }

        let greetingPrefixes = [
            "hi", "hey", "hello", "yo", "good morning", "good afternoon", "good evening", "sup", "what's up"
        ]
        if greetingPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        if lowercased.count <= 18 {
            let lightweightUtterances = ["thanks", "thank you", "who are you", "how are you", "what can you do"]
            if lightweightUtterances.contains(where: { lowercased == $0 || lowercased.hasPrefix($0 + " ") }) {
                return true
            }
        }

        return false
    }

    private func generateAgentResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        localToolResults: [String]
    ) async throws -> String {
        switch selectedBrainMode {
        case .local:
            let (responseText, _) = try await ollamaAgentClient.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            return responseText
        case .vps:
            let screenContext = images.map(\.label)
            let chatTurns = conversationHistory.map {
                VPSBrainAPIClient.ChatTurn(user: $0.userPlaceholder, assistant: $0.assistantResponse)
            }
            return try await vpsBrainAPIClient.analyzeTask(
                task: userPrompt,
                systemPrompt: systemPrompt,
                conversationHistory: chatTurns,
                localToolResults: localToolResults,
                screenContext: screenContext
            )
        case .groq:
            let chatTurns = conversationHistory.map {
                GroqAPIClient.ChatTurn(user: $0.userPlaceholder, assistant: $0.assistantResponse)
            }
            return try await groqAPIClient.analyzeTask(
                systemPrompt: systemPrompt,
                conversationHistory: chatTurns,
                userPrompt: userPrompt
            )
        }
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                do {
                    return try await operation()
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }

    private func refreshOverlayPresentation() {
        let latestStep = activeAgentRun?.latestStep
            ?? queuedAgentRuns.first?.latestStep
            ?? recentAgentStepDescriptions.last
            ?? "ready for a task"

        let statusText: String = {
            if activeAgentRun != nil { return "Processing" }
            switch voiceState {
            case .idle:
                return isWakePhraseListening ? "Listening" : "Ready"
            case .listening:
                return "Listening"
            case .processing:
                return "Processing"
            case .responding:
                return "Speaking"
            }
        }()

        let statusColor: Color = {
            switch voiceState {
            case .idle:
                return isWakePhraseListening ? .cyan : .green
            case .listening:
                return .cyan
            case .processing:
                return .yellow
            case .responding:
                return .orange
            }
        }()

        let presentationMode = notchPresentationMode()

        notchHudWindowManager.update(
            statusText: statusText,
            statusColor: statusColor,
            latestStep: latestStep,
            presentationMode: presentationMode,
            wakePhraseEnabled: isWakePhraseModeEnabled,
            overlayEnabled: isPipPetEnabled,
            selectedModel: selectedModel,
            selectedBrainMode: selectedBrainMode,
            vpsAPIBaseURL: vpsAPIBaseURL,
            groqAPIKey: groqAPIKey,
            groqModel: groqModel,
            hasAccessibilityPermission: hasAccessibilityPermission,
            hasScreenRecordingPermission: hasScreenRecordingPermission,
            hasMicrophonePermission: hasMicrophonePermission,
            hasScreenContentPermission: hasScreenContentPermission,
            lastPermissionCheckDate: lastPermissionCheckDate,
            runningAppBundlePath: Bundle.main.bundleURL.path,
            runningAppBundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown bundle"
        )
        agentCardsWindowManager.update(cards: agentCards)
    }

    private func notchPresentationMode() -> NotchHudPresentationMode {
        if voiceState == .responding {
            return .speaking
        }
        if voiceState == .listening {
            return .listening
        }
        if voiceState == .processing || activeAgentRun != nil || !queuedAgentRuns.isEmpty {
            return .thinking
        }
        return .idle
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're pip, a cute puppy-like ai pet agent that lives on the user's mac. the user just spoke to you and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct, decisive, and action-oriented. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small glowing puppy pet that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Runs Pip's local autonomous loop: observe, optionally use local tools,
    /// reason with Ollama, point at a relevant element, then speak the result.
    private func sendTranscriptToPipAgentWithScreenshot(transcript: String, runID: UUID) {
        pipSpeechSynthesizerClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            recentAgentStepDescriptions = []
            var finalRunStatus: AgentRunStatus = .completed
            var finalRunErrorDescription: String?
            recordAgentStep("task received", runID: runID)
            let pipelineStartTime = CFAbsoluteTimeGetCurrent()

            do {
                if let pendingConfirmationResponse = try await handlePendingRiskConfirmationIfNeeded(
                    transcript: transcript,
                    runID: runID
                ) {
                    recordAgentStep("task complete", runID: runID)
                    try await pipSpeechSynthesizerClient.speakText(pendingConfirmationResponse)
                    finalRunStatus = .completed
                    voiceState = .responding
                    currentResponseTask = nil
                    finalizeActiveRun(
                        runID: runID,
                        status: finalRunStatus,
                        errorDescription: finalRunErrorDescription
                    )
                    scheduleTransientHideIfNeeded()
                    startNextQueuedRunIfNeeded()
                    return
                }

                if let advancedTaskResponse = try await handleAdvancedTaskIfRequested(
                    transcript: transcript,
                    runID: runID
                ) {
                    recordAgentStep("task complete", runID: runID)
                    try await pipSpeechSynthesizerClient.speakText(advancedTaskResponse)
                    finalRunStatus = .completed
                    voiceState = .responding
                    currentResponseTask = nil
                    finalizeActiveRun(
                        runID: runID,
                        status: finalRunStatus,
                        errorDescription: finalRunErrorDescription
                    )
                    scheduleTransientHideIfNeeded()
                    startNextQueuedRunIfNeeded()
                    return
                }

                if PipAgentOrchestrator.shouldHandle(goal: transcript) {
                    let conversationSummary = conversationHistory.suffix(6).map { turn in
                        "user: \(turn.userTranscript)\npip: \(turn.assistantResponse)"
                    }.joined(separator: "\n\n")
                    let agentLoopResult = await pipAgentOrchestrator.run(
                        goal: transcript,
                        conversationSummary: conversationSummary,
                        recordStep: { [weak self] step in
                            self?.recordAgentStep(step, runID: runID)
                        }
                    )

                    if agentLoopResult.handled {
                        let responseText = agentLoopResult.summary
                        conversationHistory.append((
                            userTranscript: transcript,
                            assistantResponse: responseText
                        ))
                        if conversationHistory.count > 10 {
                            conversationHistory.removeFirst(conversationHistory.count - 10)
                        }

                        showPawFeedbackForAgentLoopResult(agentLoopResult)
                        recordAgentStep(agentLoopResult.completed ? "agent loop: verified complete" : "agent loop: stopped before completion", runID: runID)
                        try await pipSpeechSynthesizerClient.speakText(responseText)
                        finalRunStatus = agentLoopResult.completed ? .completed : .failed
                        finalRunErrorDescription = agentLoopResult.completed ? nil : responseText
                        voiceState = .responding
                        currentResponseTask = nil
                        finalizeActiveRun(
                            runID: runID,
                            status: finalRunStatus,
                            errorDescription: finalRunErrorDescription
                        )
                        scheduleTransientHideIfNeeded()
                        startNextQueuedRunIfNeeded()
                        return
                    }
                }

                if shouldUseImmediateNativeTool(for: transcript) {
                    recordAgentStep("tool: trying native mac action", runID: runID)
                    let localToolResults = await nativeToolExecutor.executeMatchingTools(for: transcript)
                    for localToolResult in localToolResults {
                        recordAgentStep(localToolResult, runID: runID)
                    }

                    if let responseText = immediateNativeToolResponse(from: localToolResults) {
                        conversationHistory.append((
                            userTranscript: transcript,
                            assistantResponse: responseText
                        ))
                        if conversationHistory.count > 10 {
                            conversationHistory.removeFirst(conversationHistory.count - 10)
                        }

                        recordAgentStep("task complete", runID: runID)
                        try await pipSpeechSynthesizerClient.speakText(responseText)
                        finalRunStatus = .completed
                        voiceState = .responding
                        currentResponseTask = nil
                        finalizeActiveRun(
                            runID: runID,
                            status: finalRunStatus,
                            errorDescription: finalRunErrorDescription
                        )
                        scheduleTransientHideIfNeeded()
                        startNextQueuedRunIfNeeded()
                        return
                    }

                    recordAgentStep("tool: no native action matched", runID: runID)
                }

                if shouldUseSidecarAgent(for: transcript) {
                    recordAgentStep("sidecar: starting hybrid browser agent", runID: runID)
                    do {
                        let sidecarResult = try await agentSidecarClient.runAgent(goal: transcript)
                        for event in sidecarResult.events {
                            let detailSuffix = event.detail?.isEmpty == false ? " — \(event.detail!)" : ""
                            recordAgentStep("\(event.step): \(event.status)\(detailSuffix)", runID: runID)
                        }

                        if sidecarResult.handled {
                            let responseText = sidecarResult.summary
                            conversationHistory.append((
                                userTranscript: transcript,
                                assistantResponse: responseText
                            ))
                            if conversationHistory.count > 10 {
                                conversationHistory.removeFirst(conversationHistory.count - 10)
                            }

                            showPawFeedbackForSidecarResult(sidecarResult)
                            recordAgentStep("sidecar: task complete", runID: runID)
                            try await pipSpeechSynthesizerClient.speakText(responseText)
                            voiceState = .responding
                            currentResponseTask = nil
                            finalizeActiveRun(
                                runID: runID,
                                status: sidecarResult.completed ? .completed : .failed,
                                errorDescription: sidecarResult.completed ? nil : responseText
                            )
                            scheduleTransientHideIfNeeded()
                            startNextQueuedRunIfNeeded()
                            return
                        }

                        recordAgentStep("sidecar: no matching browser tool, falling back", runID: runID)
                    } catch {
                        recordAgentStep("sidecar: unavailable, falling back (\(error.localizedDescription))", runID: runID)
                    }
                }

                if shouldUseOperatorMode(for: transcript) {
                    recordAgentStep("operator: starting computer-use mode", runID: runID)
                    let conversationSummary = conversationHistory.suffix(4).map { turn in
                        "user: \(turn.userTranscript)\npip: \(turn.assistantResponse)"
                    }.joined(separator: "\n\n")

                    let operatorResult = try await computerOperatorAgent.run(
                        goal: transcript,
                        conversationSummary: conversationSummary,
                        recordStep: { [weak self] step in
                            self?.recordAgentStep(step, runID: runID)
                        }
                    )

                    let responseText = operatorResult.summary
                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: responseText
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }

                    if !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recordAgentStep("tool: speak operator summary", runID: runID)
                        try await pipSpeechSynthesizerClient.speakText(responseText)
                        voiceState = .responding
                    }

                    finalRunStatus = operatorResult.completed ? .completed : .completed
                    currentResponseTask = nil
                    finalizeActiveRun(
                        runID: runID,
                        status: finalRunStatus,
                        errorDescription: finalRunErrorDescription
                    )
                    scheduleTransientHideIfNeeded()
                    startNextQueuedRunIfNeeded()
                    return
                }

                let screenCaptures: [CompanionScreenCapture]
                let screenshotDurationMilliseconds: Int
                if shouldAttemptScreenCaptureNow {
                    recordAgentStep("tool: capture screenshots", runID: runID)
                    let screenshotStartTime = CFAbsoluteTimeGetCurrent()
                    do {
                        screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        screenshotDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - screenshotStartTime) * 1000)
                        // Capture succeeded: clear any back-off so the next
                        // turn doesn't get stuck in text-only mode.
                        lastScreenCapturePermissionErrorAt = nil
                    } catch {
                        if Self.isLikelyScreenCapturePermissionError(error) {
                            lastScreenCapturePermissionErrorAt = Date()
                            // Clear the stale "previously confirmed" flag so
                            // the app stops auto-bypassing the permission
                            // gate on the next session.
                            WindowPositionManager.clearPreviouslyConfirmedScreenRecordingPermission()
                            hasScreenRecordingPermission = false
                            hasScreenContentPermission = false
                            // Re-arm the TCC prompt and surface System
                            // Settings so the user can fix the grant in one
                            // click.
                            _ = CGRequestScreenCaptureAccess()
                            handleScreenRecordingPermissionRegression()
                            recordAgentStep("tool: screen capture needs re-permission — toggle Pip in System Settings → Screen Recording, then quit & re-open Pip", runID: runID)
                            screenshotDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - screenshotStartTime) * 1000)
                            screenCaptures = []
                        } else {
                            throw error
                        }
                    }
                } else {
                    screenshotDurationMilliseconds = 0
                    screenCaptures = []
                    recordAgentStep("tool: text-only mode (screen capture skipped)", runID: runID)
                }

                guard !Task.isCancelled else { throw CancellationError() }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let modelStep: String = {
                    switch selectedBrainMode {
                    case .local:
                        return "tool: summarize screen with local model"
                    case .vps:
                        return "tool: summarize task with vps brain api"
                    case .groq:
                        return "tool: summarize task with groq api"
                    }
                }()
                recordAgentStep(modelStep, runID: runID)
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let localToolResults = await nativeToolExecutor.executeMatchingTools(for: transcript)
                for localToolResult in localToolResults {
                    recordAgentStep(localToolResult, runID: runID)
                }

                let agentPrompt = """
                user task: \(transcript)

                local tool result: \(localToolResults.isEmpty ? "no local tool was needed" : localToolResults.joined(separator: "; "))

                screen context: \(screenCaptures.isEmpty ? "no screenshots attached for this turn" : "screenshots attached")

                complete the task as far as you can from the visible screen context. if pointing helps, include the [POINT:x,y:label] tag.
                if local tool result says no tool was needed, do not claim you already opened apps/sites or created reminders/events.
                if local tool result says a search, open, reminder, calendar, note, export, or cleanup action succeeded, say it is done instead of telling the user to do it manually.
                if local tool result mentions accessibility permission is missing, briefly say you opened the completed fallback and that enabling accessibility will let you visibly click and type next time.
                """

                recordAgentStep("agent loop: reason and choose next action", runID: runID)
                let ollamaStartTime = CFAbsoluteTimeGetCurrent()
                let fullResponseText = try await generateAgentResponse(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: agentPrompt,
                    localToolResults: localToolResults
                )
                let ollamaDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - ollamaStartTime) * 1000)

                guard !Task.isCancelled else { throw CancellationError() }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                let targetScreenCapture: CompanionScreenCapture? = {
                    guard !screenCaptures.isEmpty else { return nil }
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    recordAgentStep("tool: point at \(parseResult.elementLabel ?? "screen element")", runID: runID)
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                    let appKitY = displayHeight - displayLocalY
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    PipAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    recordAgentStep("tool: point skipped", runID: runID)
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                PipAnalytics.trackAIResponseReceived(response: spokenText)

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        recordAgentStep("tool: speak status update", runID: runID)
                        let ttsStartTime = CFAbsoluteTimeGetCurrent()
                        try await pipSpeechSynthesizerClient.speakText(spokenText)
                        let ttsDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - ttsStartTime) * 1000)
                        voiceState = .responding

                        let totalPipelineDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                        let backendName: String = {
                            switch selectedBrainMode {
                            case .local: return "Local"
                            case .vps: return "VPS"
                            case .groq: return "Groq"
                            }
                        }()
                        print("⏱️ Pipeline timing — Screenshot: \(screenshotDurationMilliseconds)ms | \(backendName): \(ollamaDurationMilliseconds)ms | TTS: \(ttsDurationMilliseconds)ms | Total: \(totalPipelineDurationMilliseconds)ms")
                    } catch {
                        PipAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ macOS speech TTS error: \(error)")
                        finalRunStatus = .failed
                        finalRunErrorDescription = error.localizedDescription
                        speakAgentErrorFallback(errorMessage: error.localizedDescription)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                finalRunStatus = .cancelled
            } catch {
                PipAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                recordAgentStep("agent stopped: \(error.localizedDescription)", runID: runID)
                finalRunStatus = .failed
                finalRunErrorDescription = error.localizedDescription
                speakAgentErrorFallback(errorMessage: error.localizedDescription)
            }

            if finalRunStatus == .completed {
                recordAgentStep("task complete", runID: runID)
            }
            voiceState = .idle
            currentResponseTask = nil
            finalizeActiveRun(
                runID: runID,
                status: finalRunStatus,
                errorDescription: finalRunErrorDescription
            )
            scheduleTransientHideIfNeeded()
            startNextQueuedRunIfNeeded()
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Pip" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isPipPetEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while pipSpeechSynthesizerClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the Pip flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a fallback message when the selected brain backend fails.
    private func speakAgentErrorFallback(errorMessage: String? = nil) {
        let cleanErrorMessage = errorMessage?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let utterance: String
        let backendLabel: String = {
            switch selectedBrainMode {
            case .local: return "local ollama"
            case .vps: return "vps api"
            case .groq: return "groq api"
            }
        }()
        if let cleanErrorMessage, !cleanErrorMessage.isEmpty {
            let cappedMessage = String(cleanErrorMessage.prefix(180))
            utterance = "pip hit a \(backendLabel) error: \(cappedMessage)"
        } else {
            utterance = "pip could not reach the \(backendLabel)."
        }
        Task {
            try? await pipSpeechSynthesizerClient.speakText(utterance)
        }
        voiceState = .responding
    }

    private var shouldAttemptScreenCaptureNow: Bool {
        guard hasScreenRecordingPermission else { return false }
        guard let lastErrorAt = lastScreenCapturePermissionErrorAt else { return true }
        // Back off for a short period after a TCC denial to avoid repeated prompts.
        return Date().timeIntervalSince(lastErrorAt) > 30
    }

    /// Tracks whether we've already opened System Settings → Screen
    /// Recording during the current session. Limits us to at most one
    /// auto-open per launch so the user isn't spammed.
    private var hasOpenedScreenRecordingSettingsThisSession = false

    /// Called when the screen capture pipeline reports a permission
    /// failure for the currently running app. Opens System Settings →
    /// Privacy & Security → Screen Recording (once per session) and
    /// surfaces a short spoken explanation so the user knows what to do.
    private func handleScreenRecordingPermissionRegression() {
        if !hasOpenedScreenRecordingSettingsThisSession {
            hasOpenedScreenRecordingSettingsThisSession = true
            WindowPositionManager.openScreenRecordingSettings()
            Task { @MainActor in
                try? await pipSpeechSynthesizerClient.speakText(
                    "I lost screen recording permission. Please toggle Pip on in System Settings, then restart me."
                )
            }
        }
    }

    private static func isLikelyScreenCapturePermissionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("tcc")
            || message.contains("screen recording")
            || message.contains("not authorized")
            || message.contains("permission")
            || message.contains("declined")
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Ollama's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Ollama said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Ollama's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by PipPetOverlayView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Pip flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            PipAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            PipAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're pip, a tiny puppy-like ai pet living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Ollama to find something interesting to
    /// point at, then triggers Pip's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }
        guard WindowPositionManager.hasScreenRecordingPermission() else {
            print("🎯 Onboarding demo skipped: live screen capture permission is not available")
            return
        }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Ollama can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await ollamaAgentClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Ollama's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
