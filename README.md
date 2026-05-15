# Pip (pippy)

Pip is Ryann's OpenClaw Agenthon 2026 hackathon project: a macOS menu bar AI pet agent that can listen to a task, inspect the user's screen, reason locally, call small tools, point at UI elements, and speak back.

Repository/submission name: `OpenClaw2026_Ryann_Pip`

## What Pip Does

- Lives in the macOS menu bar with no Dock icon.
- Uses push-to-talk with `Control + Option`.
- Uses Apple Speech for speech-to-text.
- Uses local Ollama for screen-aware reasoning.
- Uses macOS `NSSpeechSynthesizer` for text-to-speech.
- Captures screenshots with ScreenCaptureKit only when the hotkey interaction runs.
- Shows a Pip puppy/paw pet overlay that can fly to UI elements referenced by the agent.
- Logs autonomous steps in the panel so judges can see tool usage and workflow execution.
- Can run local native tools such as opening apps/sites, creating reminders/events/notes, organizing Desktop files with confirmation, and exporting research summaries to PDF.
- Can visibly operate browser tasks with Accessibility/keyboard events, then fall back to direct URLs when UI automation is unavailable.

## Free Local AI Stack

Pip expects Ollama to run locally at `http://localhost:11434` and defaults to `gemma3`.

Install Ollama, then pull a model:

```bash
ollama pull gemma3
```

For stronger visual reasoning, also try:

```bash
ollama pull llama3.2-vision
```

The in-app model picker switches between `gemma3`, `supergemma:latest` if you have it locally, and `llama3.2-vision`.

Pip also includes optional experimental brain settings for a local/private VPS endpoint or Groq. These are not selected by default and are not required for judging the free local build.

## Run Locally

Requirements:

- macOS 14.2+
- Xcode 15+
- Ollama installed and running
- `gemma3` pulled with Ollama

Open the project in Xcode:

```bash
open pippy.xcodeproj
```

Select the `pippy` scheme, set your signing team if needed, then run from Xcode.

Do not run `xcodebuild` from the terminal for this project. The app relies on macOS TCC permissions such as Screen Recording and Accessibility, and command-line builds can make permission testing noisier.

## Demo Tasks

Try these during the hackathon demo:

- "Inspect my screen and guide me to the next action."
- "Find the most relevant button on screen and point to it."
- "Open Safari and tell me what I should do next."
- "Open YouTube and search up rockets." Pip opens YouTube, tries to focus/type into search, and falls back to the completed results URL if needed.
- "Look at my Xcode window and explain what needs attention."
- "Organize my Desktop." Pip previews the plan and asks before moving files.
- "Research reusable rockets and make me a PDF." Pip gathers sources and asks before exporting.

Pip's autonomous loop runs these steps:

1. Receive the spoken task.
2. Capture current screen context.
3. Optionally call a local tool such as opening a URL or app.
4. For risky actions such as moving Desktop files or exporting documents, show a confirmation step.
5. For browser actions, run a bounded operator loop that opens the site, tries Accessibility-based UI typing/clicking, observes the result, and falls back safely.
6. Ask the local Ollama model to reason over the task, screenshots, and confirmed tool results.
7. Parse a `[POINT:x,y:label:screenN]` action tag if pointing is useful.
8. Move the Pip pet overlay to the target element.
9. Speak the result with macOS local speech.

## Project Structure

```text
pippy/                              Swift source for the pippy Xcode target
  PippyApp.swift                    Menu bar app entry point
  CompanionManager.swift            Pip state machine and autonomous agent loop
  CompanionPanelView.swift          Menu bar panel UI and agent step log
  NotchHudWindowManager.swift       Floating notch HUD settings/status surface
  AgentCardsWindowManager.swift     Agent run cards for queued/running/completed tasks
  PipDockRootView.swift             Optional dock-style control surface
  OverlayWindow.swift               Pip pet overlay and pointing animation
  UIAutomationExecutor.swift        Accessibility/keyboard/mouse operator primitives
  BrowserTaskExecutor.swift         High-level browser task flows with URL fallback
  ToolExecutionResult.swift         Structured tool result surface for agent prompts
  NativeToolExecutor.swift          Local app/site/reminder/calendar/note tool calls
  DesktopCleanupEngine.swift        Desktop organization planner/executor
  WebResearchService.swift          Deterministic web source gathering
  ResearchPDFExporter.swift         PDF export for research reports
  WakePhraseCoordinator.swift       Optional Apple Speech wake phrase mode
  OllamaAgentClient.swift           Local Ollama /api/chat client
  PipSpeechSynthesizerClient.swift  macOS local TTS
  PipTranscriptionProvider.swift    Apple Speech default provider factory
  AppleSpeechTranscriptionProvider.swift
  PipDictationManager.swift         Push-to-talk audio pipeline
  PipAnalytics.swift                No-op local analytics wrapper
agent-sidecar/                      Local Playwright browser/tool automation server
```

## AI Tools / Models Used

- Ollama local chat API
- Default model: `gemma3`
- Optional local vision model: `llama3.2-vision`
- Apple Speech framework
- macOS `NSSpeechSynthesizer`
- ScreenCaptureKit

## Attribution

Pip is a hackathon project by Ryann for OpenClaw Agenthon 2026.
