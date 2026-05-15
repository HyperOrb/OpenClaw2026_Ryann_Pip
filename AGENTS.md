# Pip - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar AI pet agent. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens custom Pip control surfaces with companion voice controls, agent cards, and a visible agent-step log. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it with Apple Speech, captures screenshots with ScreenCaptureKit, reasons with a local Ollama model, speaks via macOS `NSSpeechSynthesizer`, and animates a warm Pip pet overlay to point at UI elements.

The default hackathon build requires no paid API keys.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Agent**: Local Ollama via `OllamaAgentClient` (`gemma3` default, `llama3.2-vision` optional)
- **Speech-to-Text**: Apple Speech via `AppleSpeechTranscriptionProvider`
- **Text-to-Speech**: macOS `NSSpeechSynthesizer` via `PipSpeechSynthesizerClient`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Agent Loop**: `CompanionManager` observes the spoken task, captures screenshots, optionally calls local tools, asks Ollama to reason, parses tool/action tags, points at UI, and speaks the result.
- **Local Tools**: `NativeToolExecutor`, `UIAutomationExecutor`, `BrowserTaskExecutor`, `DesktopCleanupEngine`, `WebResearchService`, and `ResearchPDFExporter` support visible browser operation, app/site opening, reminders/events/notes, guarded Desktop cleanup, and research PDF export.
- **Optional Brain Modes**: Local Ollama is the default. VPS and Groq clients are optional, non-default experiment paths and must not be required for the hackathon build.
- **Element Pointing**: Ollama embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the Pip pet along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: Local no-op wrapper via `PipAnalytics.swift`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Pip Pet Overlay**: A full-screen transparent `NSPanel` hosts the Pip pet companion. It's non-activating, joins all Spaces, and never steals focus. The pet position, response bubbles, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Free Local Stack**: Pip defaults to Apple Speech, Ollama, and macOS speech synthesis so judges can run it without paid API accounts.

**Transient Pet Mode**: When "Show Pip" is off, pressing the hotkey fades in the overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `PippyApp.swift` | ~60 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which starts `CompanionManager`. No main window — the app lives in accessory mode. |
| `CompanionManager.swift` | ~1940 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Ollama agent calls, optional brain modes, local tools, guarded risk confirmations, local TTS, tool-step logging, agent cards, and overlay management. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1010 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, brain/model picker, wake phrase controls, permissions UI, agent step log, and quit button. |
| `NotchHudWindowManager.swift` | ~790 | Floating notch-style HUD for Pip status, model/brain settings, wake phrase controls, and quick controls. |
| `AgentCardsWindowManager.swift` | ~260 | Window manager for agent run cards and follow-up actions. |
| `PipDockRootView.swift` | ~260 | Optional dock-style control surface showing agent cards, follow-up input, and model controls. |
| `OverlayWindow.swift` | ~900 | Full-screen transparent overlay hosting the Pip pet, response text, waveform, and spinner. Handles pet animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `PipDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, Apple Speech sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `PipTranscriptionProvider.swift` | ~42 | Protocol surface and provider factory for voice transcription. Defaults to Apple Speech. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local transcription provider backed by Apple's Speech framework. |
| `PipAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads if needed. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `UIAutomationExecutor.swift` | ~240 | Accessibility, keyboard, and mouse primitives for Pip's visible operator mode. |
| `BrowserTaskExecutor.swift` | ~220 | High-level browser task executor for YouTube/Google/GitHub/X searches with UI automation first and direct URL fallback. |
| `ToolExecutionResult.swift` | ~20 | Structured local tool result used to feed confirmed action state back into the agent loop. |
| `NativeToolExecutor.swift` | ~370 | Local tool dispatcher for opening URLs/apps/sites, web search, reminders, calendar events, Notes, and workflow handoffs. |
| `DesktopCleanupEngine.swift` | ~165 | Plans and executes Desktop organization tasks with risk classification and verification. |
| `WebResearchService.swift` | ~90 | Deterministic source gathering for research workflows. |
| `ResearchPDFExporter.swift` | ~70 | Exports research reports to PDF in the user's Documents folder. |
| `WakePhraseCoordinator.swift` | ~200 | Optional always-listening Apple Speech wake phrase detector for "hey pip agent". |
| `OllamaAgentClient.swift` | ~110 | Local Ollama `/api/chat` streaming client with screenshot image support. |
| `PipSpeechSynthesizerClient.swift` | ~28 | Local macOS speech synthesis client. |
| `GroqAPIClient.swift` | ~125 | Optional non-default Groq client for experiments. Do not require it for the default build. |
| `VPSBrainAPIClient.swift` | ~125 | Optional non-default local/private brain endpoint client. Defaults to localhost. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `PipAnalytics.swift` | ~80 | No-op analytics wrapper that preserves centralized instrumentation call sites without external analytics. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |

## Build & Run

```bash
# Open in Xcode
open pippy.xcodeproj

# Local model dependency
ollama pull gemma3

# Select the pippy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
