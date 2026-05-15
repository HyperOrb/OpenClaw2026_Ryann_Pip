//
//  NotchHudWindowManager.swift
//  pippy
//
//  Notch HUD with compact/expanded states and launcher button.
//

import AppKit
import Combine
import SwiftUI

enum NotchHudTab: String {
    case home
    case agent
}

enum NotchHudPresentationMode: String {
    case idle
    case listening
    case thinking
    case speaking
}

private enum NotchHudExpansionState {
    case compact
    case active
    case hover
}

@MainActor
final class NotchHudWindowManager {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Hosting view that only forwards mouse hits inside the currently
    /// visible notch silhouette. Areas outside the silhouette pass clicks
    /// through to the underlying app windows.
    ///
    /// `visibleContentRect` returns the silhouette rect in *local* view
    /// coordinates, accounting for NSHostingView's flipped coordinate
    /// system (origin at top-left).
    fileprivate final class NotchHostingView<Content: View>: NSHostingView<Content> {
        var visibleContentRect: (() -> CGRect)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let rectProvider = visibleContentRect else {
                return super.hitTest(point)
            }
            let localPoint = convert(point, from: superview)
            if rectProvider().contains(localPoint) {
                return super.hitTest(point)
            }
            return nil
        }
    }

    fileprivate final class NotchHudModel: ObservableObject {
        @Published var expansionState: NotchHudExpansionState = .compact
        @Published var statusText: String = "Ready"
        @Published var statusColor: Color = .green
        @Published var latestStep: String = "ready for a task"
        @Published var presentationMode: NotchHudPresentationMode = .idle
        @Published var selectedTab: NotchHudTab = .home
        @Published var showSettings: Bool = false
        @Published var settingsPinned: Bool = false
        @Published var isHovering: Bool = false
        @Published var contentVisible: Bool = true
        @Published var wakePhraseEnabled: Bool = false
        @Published var overlayEnabled: Bool = true
        @Published var selectedModel: String = "gemma3:latest"
        @Published var selectedBrainMode: PipBrainMode = .local
        @Published var vpsAPIBaseURL: String = "http://localhost:3000"
        @Published var groqAPIKey: String = ""
        @Published var groqModel: String = "llama-3.1-8b-instant"
        @Published var hasAccessibilityPermission: Bool = false
        @Published var hasScreenRecordingPermission: Bool = false
        @Published var hasMicrophonePermission: Bool = false
        @Published var hasScreenContentPermission: Bool = false
        @Published var lastPermissionCheckDate: Date?
        @Published var runningAppBundlePath: String = ""
        @Published var runningAppBundleIdentifier: String = ""

        var onHoverChanged: ((Bool) -> Void)?
        var onToggleWakePhrase: ((Bool) -> Void)?
        var onToggleOverlay: ((Bool) -> Void)?
        var onSelectModel: ((String) -> Void)?
        var onSelectBrainMode: ((PipBrainMode) -> Void)?
        var onSaveVPSBaseURL: ((String) -> Void)?
        var onSaveGroqConfig: ((String, String) -> Void)?
        var onCheckPermissions: (() -> Void)?
        var onFixPermissions: (() -> Void)?
        var onRequestExpandSettings: (() -> Void)?
    }

    fileprivate final class LauncherButtonModel: ObservableObject {
        var onPressed: (() -> Void)?
    }

    private let model = NotchHudModel()
    private let launcherModel = LauncherButtonModel()
    private var panel: NSPanel?
    private var launcherPanel: NSPanel?
    private var hoverDebounceTask: Task<Void, Never>?
    private var globalMouseTrackingMonitor: Any?
    private var localMouseTrackingMonitor: Any?
    private let panelSize = NSSize(width: 580, height: 480)
    private let panelTopOffset: CGFloat = -1

    deinit {
        if let globalMouseTrackingMonitor {
            NSEvent.removeMonitor(globalMouseTrackingMonitor)
        }
        if let localMouseTrackingMonitor {
            NSEvent.removeMonitor(localMouseTrackingMonitor)
        }
    }

    func setCallbacks(
        onToggleWakePhrase: @escaping (Bool) -> Void,
        onToggleOverlay: @escaping (Bool) -> Void,
        onSelectModel: @escaping (String) -> Void,
        onSelectBrainMode: @escaping (PipBrainMode) -> Void,
        onSaveVPSBaseURL: @escaping (String) -> Void,
        onSaveGroqConfig: @escaping (String, String) -> Void,
        onCheckPermissions: @escaping () -> Void,
        onFixPermissions: @escaping () -> Void
    ) {
        model.onToggleWakePhrase = onToggleWakePhrase
        model.onToggleOverlay = onToggleOverlay
        model.onSelectModel = onSelectModel
        model.onSelectBrainMode = onSelectBrainMode
        model.onSaveVPSBaseURL = onSaveVPSBaseURL
        model.onSaveGroqConfig = onSaveGroqConfig
        model.onCheckPermissions = onCheckPermissions
        model.onFixPermissions = onFixPermissions
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        if launcherPanel == nil {
            createLauncherPanel()
        }
        repositionOnActiveScreen()
        startMouseTrackingMonitorsIfNeeded()
        updatePanelMouseEventPassthrough()
        panel?.orderFrontRegardless()
        launcherPanel?.orderFrontRegardless()
    }

    func hide() {
        hoverDebounceTask?.cancel()
        stopMouseTrackingMonitors()
        panel?.orderOut(nil)
        launcherPanel?.orderOut(nil)
    }

    func update(
        statusText: String,
        statusColor: Color,
        latestStep: String,
        presentationMode: NotchHudPresentationMode,
        wakePhraseEnabled: Bool,
        overlayEnabled: Bool,
        selectedModel: String,
        selectedBrainMode: PipBrainMode,
        vpsAPIBaseURL: String,
        groqAPIKey: String,
        groqModel: String,
        hasAccessibilityPermission: Bool,
        hasScreenRecordingPermission: Bool,
        hasMicrophonePermission: Bool,
        hasScreenContentPermission: Bool,
        lastPermissionCheckDate: Date?,
        runningAppBundlePath: String,
        runningAppBundleIdentifier: String
    ) {
        model.statusText = statusText
        model.statusColor = statusColor
        model.latestStep = latestStep
        model.presentationMode = presentationMode
        model.wakePhraseEnabled = wakePhraseEnabled
        model.overlayEnabled = overlayEnabled
        model.selectedModel = selectedModel
        model.selectedBrainMode = selectedBrainMode
        model.vpsAPIBaseURL = vpsAPIBaseURL
        model.groqAPIKey = groqAPIKey
        model.groqModel = groqModel
        model.hasAccessibilityPermission = hasAccessibilityPermission
        model.hasScreenRecordingPermission = hasScreenRecordingPermission
        model.hasMicrophonePermission = hasMicrophonePermission
        model.hasScreenContentPermission = hasScreenContentPermission
        model.lastPermissionCheckDate = lastPermissionCheckDate
        model.runningAppBundlePath = runningAppBundlePath
        model.runningAppBundleIdentifier = runningAppBundleIdentifier

        if presentationMode != .idle {
            model.showSettings = false
        }
        updateExpansionState(animated: true)
        updatePanelMouseEventPassthrough()
    }

    private func createPanel() {
        model.onHoverChanged = { [weak self] isHovering in
            guard let self else { return }
            // Don't let an incidental hover-leave (e.g. cursor crossing a
            // child button's tracking area) collapse the HUD while the
            // user has explicitly pinned settings open.
            if !isHovering && self.model.settingsPinned {
                return
            }
            self.model.isHovering = isHovering
            self.scheduleHoverAwareExpansionUpdate(isHovering: isHovering)
        }
        model.onRequestExpandSettings = { [weak self] in
            guard let self else { return }
            self.hoverDebounceTask?.cancel()
            // Don't pin the settings open – treat the click like a hover
            // open, so the HUD auto-collapses when the user moves their
            // mouse away from the notch area.
            self.model.settingsPinned = false
            self.model.showSettings = true
            self.model.isHovering = true
            self.model.contentVisible = true
            self.updateExpansionState(animated: true)
        }

        let rootView = NotchHudView(model: model)
        let hostingView = NotchHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.visibleContentRect = { [weak self] in
            self?.currentVisibleContentRect() ?? .zero
        }

        let notchPanel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.isFloatingPanel = true
        notchPanel.level = .statusBar
        notchPanel.backgroundColor = .clear
        notchPanel.isOpaque = false
        notchPanel.hasShadow = true
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notchPanel.hidesOnDeactivate = false
        notchPanel.ignoresMouseEvents = false
        notchPanel.isMovableByWindowBackground = false
        notchPanel.contentView = hostingView
        panel = notchPanel
        updatePanelMouseEventPassthrough()
    }

    /// The visible silhouette of the notch HUD in the hosting view's
    /// *flipped* local coordinate space (top-left origin). Must match the
    /// SwiftUI content sizing logic in `NotchHudView`.
    private func currentVisibleContentRect() -> CGRect {
        let cw: CGFloat
        let ch: CGFloat
        switch model.expansionState {
        case .compact:
            cw = 180; ch = 34
        case .active:
            cw = 340; ch = 36
        case .hover:
            cw = 540
            if model.showSettings {
                switch model.selectedBrainMode {
                case .local: ch = 430
                case .vps:   ch = 455
                case .groq:  ch = 475
                }
            } else {
                ch = 96
            }
        }
        // SwiftUI body is sized `panelSize` with `.top` alignment, so the
        // visible silhouette sits at the top center of the view (y=0 in
        // flipped coords). Add a small padding so clicks slightly outside
        // the visual edge (e.g. on shadow) still register.
        let originX = (panelSize.width - cw) / 2
        return CGRect(x: originX - 2, y: -2, width: cw + 4, height: ch + 4)
    }

    private func createLauncherPanel() {
        launcherModel.onPressed = { [weak self] in
            guard let self else { return }
            self.model.isHovering.toggle()
            self.updateExpansionState(animated: true)
        }

        let launcherView = NotchLauncherButtonView(model: launcherModel)
        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 34, height: 34)

        let launcher = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        launcher.isFloatingPanel = true
        launcher.level = .statusBar
        launcher.backgroundColor = .clear
        launcher.isOpaque = false
        launcher.hasShadow = true
        launcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        launcher.hidesOnDeactivate = false
        launcher.ignoresMouseEvents = false
        launcher.isMovableByWindowBackground = false
        launcher.contentView = hostingView
        launcherPanel = launcher
    }

    private func repositionOnActiveScreen() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let x = screen.frame.midX - (panelSize.width / 2)
        let y = screen.frame.maxY - panelSize.height - panelTopOffset
        let targetFrame = NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: false)
        }

        if let launcherPanel {
            let launcherSize: CGFloat = 34
            let launcherX = screen.frame.maxX - launcherSize - 18
            let launcherY = screen.frame.maxY - launcherSize - 12
            let launcherTarget = NSRect(x: launcherX, y: launcherY, width: launcherSize, height: launcherSize)
            if launcherPanel.frame != launcherTarget {
                launcherPanel.setFrame(launcherTarget, display: false)
            }
        }
        updatePanelMouseEventPassthrough()
    }

    private func scheduleHoverAwareExpansionUpdate(isHovering: Bool) {
        hoverDebounceTask?.cancel()
        if isHovering {
            withAnimation(.easeInOut(duration: 0.12)) {
                model.contentVisible = false
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 65_000_000)
                withAnimation(.easeInOut(duration: 0.16)) {
                    self?.model.contentVisible = true
                }
            }
            updateExpansionState(animated: true)
            return
        }

        if model.settingsPinned {
            return
        }

        // Small delay prevents jitter when cursor briefly leaves notch area.
        hoverDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            await MainActor.run {
                self?.updateExpansionState(animated: true)
            }
        }
    }

    private func updateExpansionState(animated: Bool) {
        let nextState: NotchHudExpansionState
        if model.isHovering || model.settingsPinned {
            nextState = .hover
        } else if model.presentationMode != .idle {
            nextState = .active
        } else {
            nextState = .compact
        }

        if nextState != .hover {
            model.showSettings = false
            model.settingsPinned = false
        }
        model.expansionState = nextState
        updatePanelMouseEventPassthrough()
    }

    private func startMouseTrackingMonitorsIfNeeded() {
        guard globalMouseTrackingMonitor == nil, localMouseTrackingMonitor == nil else { return }
        let matchingEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        globalMouseTrackingMonitor = NSEvent.addGlobalMonitorForEvents(matching: matchingEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePanelMouseEventPassthrough()
            }
        }

        localMouseTrackingMonitor = NSEvent.addLocalMonitorForEvents(matching: matchingEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updatePanelMouseEventPassthrough()
            }
            return event
        }
    }

    private func stopMouseTrackingMonitors() {
        if let globalMouseTrackingMonitor {
            NSEvent.removeMonitor(globalMouseTrackingMonitor)
            self.globalMouseTrackingMonitor = nil
        }
        if let localMouseTrackingMonitor {
            NSEvent.removeMonitor(localMouseTrackingMonitor)
            self.localMouseTrackingMonitor = nil
        }
        panel?.ignoresMouseEvents = true
    }

    /// AppKit windows either participate in cross-app mouse routing or they
    /// don't. Returning nil from a content-view hit test is not enough to let
    /// clicks fall through to other apps, so the transparent HUD window must
    /// ignore mouse events whenever the pointer is outside the visible notch.
    private func updatePanelMouseEventPassthrough() {
        guard let panel else { return }
        let visibleRect = currentVisibleContentScreenRect()
        let shouldAcceptMouseEvents = visibleRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !shouldAcceptMouseEvents
    }

    private func currentVisibleContentScreenRect() -> CGRect {
        guard let panel else { return .zero }
        let localRectWithTopLeftOrigin = currentVisibleContentRect()
        return CGRect(
            x: panel.frame.minX + localRectWithTopLeftOrigin.minX,
            y: panel.frame.maxY - localRectWithTopLeftOrigin.maxY,
            width: localRectWithTopLeftOrigin.width,
            height: localRectWithTopLeftOrigin.height
        )
    }
}

private struct NotchHudView: View {
    @ObservedObject var model: NotchHudWindowManager.NotchHudModel
    @State private var vpsURLDraft: String = ""
    @State private var groqKeyDraft: String = ""
    @State private var groqModelDraft: String = ""
    @State private var phase: CGFloat = 0

    private let pulseAnimation = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    private let thinkingAnimation = Animation.linear(duration: 1.2).repeatForever(autoreverses: false)
    private let speakingAnimation = Animation.easeInOut(duration: 0.42).repeatForever(autoreverses: true)

    var body: some View {
        ZStack(alignment: .top) {
            notchContent
                .onHover { isHovering in
                    model.onHoverChanged?(isHovering)
                }
        }
        .frame(width: 580, height: 480, alignment: .top)
        .onAppear {
            vpsURLDraft = model.vpsAPIBaseURL
            groqKeyDraft = model.groqAPIKey
            groqModelDraft = model.groqModel
            phase = 1
        }
        .onChange(of: model.vpsAPIBaseURL) { newValue in
            if model.selectedBrainMode == .vps {
                vpsURLDraft = newValue
            }
        }
        .onChange(of: model.groqAPIKey) { newValue in
            if model.selectedBrainMode == .groq {
                groqKeyDraft = newValue
            }
        }
        .onChange(of: model.groqModel) { newValue in
            if model.selectedBrainMode == .groq {
                groqModelDraft = newValue
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.contentVisible)
        .animation(.easeInOut(duration: 0.2), value: model.expansionState)
    }

    private var notchContent: some View {
        Group {
            if model.expansionState == .hover {
                expandedContent
            } else {
                compactContent
            }
        }
        .opacity(model.contentVisible ? 1 : 0.93)
        .scaleEffect(model.contentVisible ? 1 : 0.985)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
        .frame(width: contentWidth, height: contentHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var containerCornerRadius: CGFloat {
        switch model.expansionState {
        case .compact, .active:
            return 15
        case .hover:
            return 14
        }
    }

    private var contentWidth: CGFloat {
        switch model.expansionState {
        case .compact:
            return 180
        case .active:
            return 340
        case .hover:
            return 540
        }
    }

    private var contentHeight: CGFloat {
        switch model.expansionState {
        case .compact:
            return 34
        case .active:
            return 36
        case .hover:
            return contentHeightForHover()
        }
    }

    /// Returns the natural height of the expanded HUD given the currently
    /// active brain mode (Groq needs the most space because it shows two
    /// text fields).
    private func contentHeightForHover() -> CGFloat {
        if !model.showSettings {
            return 96
        }
        switch model.selectedBrainMode {
        case .local:
            return 430
        case .vps:
            return 455
        case .groq:
            return 475
        }
    }

    private var horizontalInset: CGFloat {
        switch model.expansionState {
        case .compact:
            return 12
        case .active:
            return 13
        case .hover:
            return 13
        }
    }

    private var verticalInset: CGFloat {
        switch model.expansionState {
        case .compact:
            return 3
        case .active:
            return 4
        case .hover:
            return 8
        }
    }

    private var compactContent: some View {
        HStack(spacing: 8) {
            stateIndicator
            if model.expansionState != .compact {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .transition(.opacity)
            }
            Text(model.statusText)
                .font(.system(size: model.expansionState == .compact ? 10 : 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.expansionState == .active {
                modeMicroViz
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            gearTapButton(iconSize: 9, diameter: 16)
        }
    }

    private func gearTapButton(iconSize: CGFloat, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.16))
            Image(systemName: "gearshape.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
        }
        .frame(width: diameter, height: diameter)
        // Expand the hit area well beyond the visible circle so the tap can
        // never miss in compact mode.
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture {
            openSettings()
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                tabButton(.home, label: "Home")
                tabButton(.agent, label: "Agent")
                Spacer()
                gearTapButton(iconSize: 12, diameter: 24)
            }

            HStack(spacing: 10) {
                stateIndicator
                Text("Hold control + option to talk.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                modeMicroViz
                Text(model.statusText.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.78))
            }

            Text(model.latestStep)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.white.opacity(0.68))

            if model.showSettings {
                settingsSection
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Wake Phrase", isOn: Binding(
                get: { model.wakePhraseEnabled },
                set: { model.onToggleWakePhrase?($0) }
            ))
            .toggleStyle(.switch)

            Toggle("Show Pip Cursor", isOn: Binding(
                get: { model.overlayEnabled },
                set: { model.onToggleOverlay?($0) }
            ))
            .toggleStyle(.switch)

            permissionStatusSection

            HStack(spacing: 6) {
                modelChoiceButton("gemma3:latest", label: "Gemma Vision")
                modelChoiceButton("supergemma:latest", label: "Super")
                modelChoiceButton("llama3.2-vision", label: "Vision")
            }

            HStack(spacing: 6) {
                brainChoiceButton(.local, label: "Local")
                brainChoiceButton(.vps, label: "VPS")
                brainChoiceButton(.groq, label: "Groq")
            }

            if model.selectedBrainMode == .vps {
                HStack(spacing: 6) {
                    TextField("http://localhost:3000", text: $vpsURLDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )

                    Button("Save") {
                        model.onSaveVPSBaseURL?(vpsURLDraft)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.blue.opacity(0.45))
                    )
                    .foregroundColor(.white)
                }
            } else if model.selectedBrainMode == .groq {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("gsk_...", text: $groqKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )

                    HStack(spacing: 6) {
                        TextField("llama-3.1-8b-instant", text: $groqModelDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                            )

                        Button("Save") {
                            model.onSaveGroqConfig?(groqKeyDraft, groqModelDraft)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.blue.opacity(0.45))
                        )
                        .foregroundColor(.white)
                    }
                }
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .bold))
                    Text("Quit Pip")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.36))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.red.opacity(0.32), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
        }
    }

    private var permissionStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Permissions")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text(permissionCheckTimestampText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Button {
                    model.onCheckPermissions?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                        Text("Check")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.9))

                Button {
                    model.onFixPermissions?()
                } label: {
                    Text("Fix")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.blue.opacity(0.38))
                        )
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ],
                spacing: 6
            ) {
                permissionChip(title: "Accessibility", isGranted: model.hasAccessibilityPermission)
                permissionChip(title: "Screen Recording", isGranted: model.hasScreenRecordingPermission)
                permissionChip(title: "Microphone", isGranted: model.hasMicrophonePermission)
                permissionChip(title: "Screen Content", isGranted: model.hasScreenContentPermission)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Running: \(model.runningAppBundleIdentifier)")
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(0.5))
                Text(model.runningAppBundlePath)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.white.opacity(0.42))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
        )
    }

    private var permissionCheckTimestampText: String {
        guard let lastPermissionCheckDate = model.lastPermissionCheckDate else {
            return "not checked"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastPermissionCheckDate, relativeTo: Date())
    }

    private func permissionChip(title: String, isGranted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isGranted ? .green : .yellow)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(.white.opacity(0.82))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func tabButton(_ tab: NotchHudTab, label: String) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(model.selectedTab == tab ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                )
                .foregroundColor(.white.opacity(0.92))
        }
        .buttonStyle(.plain)
    }

    private func modelChoiceButton(_ modelID: String, label: String) -> some View {
        Button {
            model.onSelectModel?(modelID)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.selectedModel == modelID ? Color.blue.opacity(0.45) : Color.white.opacity(0.12))
                )
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private func brainChoiceButton(_ mode: PipBrainMode, label: String) -> some View {
        Button {
            model.onSelectBrainMode?(mode)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.selectedBrainMode == mode ? Color.green.opacity(0.42) : Color.white.opacity(0.12))
                )
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private var stateIndicator: some View {
        Circle()
            .fill(model.statusColor)
            .frame(width: 8, height: 8)
            .scaleEffect(model.presentationMode == .listening ? (phase > 0.5 ? 1.22 : 0.88) : 1)
            .shadow(color: model.statusColor.opacity(model.presentationMode == .listening ? 0.85 : 0.45), radius: model.presentationMode == .listening ? 7 : 3)
            .animation(model.presentationMode == .listening ? pulseAnimation : .default, value: phase)
    }

    @ViewBuilder
    private var modeMicroViz: some View {
        switch model.presentationMode {
        case .idle:
            EmptyView()
        case .listening:
            Capsule()
                .fill(Color.cyan.opacity(0.88))
                .frame(width: 22, height: 4)
                .opacity(phase > 0.5 ? 1 : 0.55)
                .animation(pulseAnimation, value: phase)
        case .thinking:
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 26, height: 4)
                Capsule()
                    .fill(Color.yellow.opacity(0.92))
                    .frame(width: 11, height: 4)
                    .offset(x: phase > 0.5 ? 14 : 0)
            }
            .animation(thinkingAnimation, value: phase)
        case .speaking:
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.orange.opacity(0.92))
                        .frame(width: 3, height: barHeight(for: index))
                }
            }
            .animation(speakingAnimation, value: phase)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard model.presentationMode == .speaking else { return 4 }
        switch index {
        case 0: return phase > 0.5 ? 8 : 4
        case 1: return phase > 0.5 ? 4 : 9
        default: return phase > 0.5 ? 7 : 5
        }
    }

    private func openSettings() {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.onRequestExpandSettings?()
        }
    }
}

private struct NotchLauncherButtonView: View {
    @ObservedObject var model: NotchHudWindowManager.LauncherButtonModel

    var body: some View {
        Button {
            model.onPressed?()
        } label: {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.82))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
