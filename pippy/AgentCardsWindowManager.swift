//
//  AgentCardsWindowManager.swift
//  pippy
//
//  Always-on-top clickable floating agent cards.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AgentCardsWindowManager {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    final class AgentCardsModel: ObservableObject {
        @Published var cards: [AgentCardSnapshot] = []
        @Published var draftText: String = ""
        @Published var selectedCardID: UUID?
        var onStopCard: ((UUID) -> Void)?
        var onSendFollowUp: ((String) -> Void)?
    }

    private let model = AgentCardsModel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            createPanel()
        }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func update(cards: [AgentCardSnapshot]) {
        model.cards = cards.sorted(by: { $0.updatedAt > $1.updatedAt })
        if model.selectedCardID == nil {
            model.selectedCardID = model.cards.first?.id
        }
    }

    func setCallbacks(
        onStopCard: @escaping (UUID) -> Void,
        onSendFollowUp: @escaping (String) -> Void
    ) {
        model.onStopCard = onStopCard
        model.onSendFollowUp = onSendFollowUp
    }

    private func createPanel() {
        let view = AgentCardsOverlayView(model: model)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 420)

        let floatingPanel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.isFloatingPanel = true
        floatingPanel.level = .statusBar
        floatingPanel.backgroundColor = .clear
        floatingPanel.isOpaque = false
        floatingPanel.hasShadow = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.ignoresMouseEvents = false
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.contentView = hostingView
        panel = floatingPanel
    }

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let width: CGFloat = 360
        let height: CGFloat = 420
        let x = screen.frame.maxX - width - 20
        let y = screen.frame.maxY - height - 84
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private struct AgentCardsOverlayView: View {
    @ObservedObject var model: AgentCardsWindowManager.AgentCardsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            followUpComposer
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.cards) { card in
                        cardRow(card)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack {
            Text("Agents")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text("\(model.cards.count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var followUpComposer: some View {
        HStack(spacing: 8) {
            TextField("Follow up current agent…", text: $model.draftText)
                .textFieldStyle(.roundedBorder)
            Button("Send") {
                let trimmed = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.onSendFollowUp?(trimmed)
                model.draftText = ""
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func cardRow(_ card: AgentCardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.title.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(card.status.rawValue.capitalized)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(colorForStatus(card.status))
            }
            Text(card.latestStep)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.white.opacity(0.8))
            Text(card.lastTranscript)
                .font(.system(size: 10, weight: .regular))
                .lineLimit(2)
                .foregroundColor(.white.opacity(0.65))

            if card.status == .running {
                Button(role: .destructive) {
                    model.onStopCard?(card.id)
                } label: {
                    Text("Stop")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func colorForStatus(_ status: AgentRunStatus) -> Color {
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
