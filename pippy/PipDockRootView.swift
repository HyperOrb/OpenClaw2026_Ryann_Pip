//
//  PipDockRootView.swift
//  pippy
//
//  Dock-first control surface for Pip with live state and multi-agent cards.
//

import AppKit
import SwiftUI

struct PipDockRootView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(Color.black.opacity(0.9))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pip")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text("Hold control + option to talk")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.72))

            statusChip

            Toggle("Wake Phrase", isOn: Binding(
                get: { companionManager.isWakePhraseModeEnabled },
                set: { companionManager.setWakePhraseModeEnabled($0) }
            ))
            .toggleStyle(.switch)

            Toggle("Show Pip Overlay", isOn: Binding(
                get: { companionManager.isPipPetEnabled },
                set: { companionManager.setPipPetEnabled($0) }
            ))
            .toggleStyle(.switch)

            modelPicker

            Divider()
                .overlay(Color.white.opacity(0.15))

            Text("Follow up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            TextField("Ask follow-up as text…", text: $companionManager.typedFollowUpDraft)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(action: {
                    companionManager.submitTypedFollowUp()
                }) {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("AI Text")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: {}) {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Voice")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Quit Pip") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(22)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Agents")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text("\(companionManager.agentCards.count) total")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(companionManager.agentCards.sorted(by: { $0.updatedAt > $1.updatedAt })) { card in
                        agentCard(card)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 20)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colorForVoiceState)
                .frame(width: 8, height: 8)
            Text(statusText.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(colorForVoiceState.opacity(0.2)))
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            HStack(spacing: 6) {
                modelButton("gemma3:latest", label: "Gemma Vision")
                modelButton("supergemma:latest", label: "Super")
                modelButton("llama3.2-vision", label: "Vision")
            }
        }
    }

    private func modelButton(_ modelID: String, label: String) -> some View {
        Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(companionManager.selectedModel == modelID ? Color.blue.opacity(0.45) : Color.white.opacity(0.1))
                )
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private func agentCard(_ card: AgentCardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title.capitalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(card.status.rawValue.capitalized)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(colorForRunStatus(card.status).opacity(0.2)))
                    .foregroundColor(colorForRunStatus(card.status))
            }

            Text(card.latestStep)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            Text(card.lastTranscript)
                .font(.system(size: 11, weight: .regular))
                .lineLimit(2)
                .foregroundColor(.white.opacity(0.65))

            Text("Runs: \(card.runIDs.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            if card.status == .running {
                Button(role: .destructive, action: {
                    companionManager.cancelActiveAgentCard(card.id)
                }) {
                    Text("Stop Agent")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var statusText: String {
        if companionManager.activeAgentRun != nil {
            return "processing"
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isWakePhraseListening ? "listening" : "ready"
        case .listening:
            return "listening"
        case .processing:
            return "processing"
        case .responding:
            return "speaking"
        }
    }

    private var colorForVoiceState: Color {
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isWakePhraseListening ? .cyan : .green
        case .listening:
            return .cyan
        case .processing:
            return .yellow
        case .responding:
            return .orange
        }
    }

    private func colorForRunStatus(_ status: AgentRunStatus) -> Color {
        switch status {
        case .queued:
            return .blue
        case .running:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }
}
