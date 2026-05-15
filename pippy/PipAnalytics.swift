//
//  PipAnalytics.swift
//  pippy
//
//  Local no-op analytics wrapper for the hackathon fork.
//  Pip keeps the call sites centralized without shipping any external analytics key.
//

import Foundation

enum PipAnalytics {

    // MARK: - Setup

    static func configure() {
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
    }

    /// The onboarding demo interaction where Pip points at something.
    static func trackOnboardingDemoTriggered() {
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
    }

    /// The local agent responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
    }

    /// The local agent response included a [POINT:x,y:label] coordinate tag,
    /// so the Pip pet is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
    }
}
