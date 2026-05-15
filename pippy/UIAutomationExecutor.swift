//
//  UIAutomationExecutor.swift
//  pippy
//
//  Accessibility and keyboard/mouse primitives for Pip's visible operator mode.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class UIAutomationExecutor {
    struct FocusedAppObservation {
        let appName: String
        let bundleIdentifier: String?
        let focusedWindowTitle: String?
        let focusedWindowFrame: CGRect?
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    var hasAccessibilityPermission: Bool {
        WindowPositionManager.shouldTreatAccessibilityPermissionAsGrantedForSessionLaunch()
    }

    var hasLiveAccessibilityPermission: Bool {
        WindowPositionManager.hasAccessibilityPermission()
    }

    func requestAccessibilityPermissionPrompt() {
        _ = WindowPositionManager.requestAccessibilityPermission()
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func activateApp(named appName: String) -> Bool {
        if let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            return runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        return NSWorkspace.shared.launchApplication(appName)
    }

    func observeFocusedApp() -> FocusedAppObservation {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApplication?.localizedName ?? "unknown app"
        let bundleIdentifier = frontmostApplication?.bundleIdentifier
        var windowTitle: String?

        if let processIdentifier = frontmostApplication?.processIdentifier {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            windowTitle = focusedWindowTitle(for: appElement)
        }

        return FocusedAppObservation(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            focusedWindowTitle: windowTitle,
            focusedWindowFrame: focusedWindowFrame()
        )
    }

    func clickApproximateSearchAreaAndSubmit(
        query: String,
        verticalOffsetFromWindowTop: CGFloat,
        horizontalPositionInWindow: CGFloat = 0.5
    ) async -> Bool {
        await clickApproximateSearchAreaAndType(
            query: query,
            verticalOffsetFromWindowTop: verticalOffsetFromWindowTop,
            horizontalPositionInWindow: horizontalPositionInWindow,
            submit: true
        )
    }

    func clickApproximateSearchAreaAndType(
        query: String,
        verticalOffsetFromWindowTop: CGFloat,
        horizontalPositionInWindow: CGFloat = 0.5,
        submit: Bool
    ) async -> Bool {
        let windowFrame = focusedWindowFrame() ?? fallbackFrontmostWindowFrame()
        guard let windowFrame else { return false }

        let clickPoint = CGPoint(
            x: windowFrame.minX + (windowFrame.width * horizontalPositionInWindow),
            y: windowFrame.minY + verticalOffsetFromWindowTop
        )

        moveMouse(to: clickPoint)
        try? await Task.sleep(nanoseconds: 220_000_000)
        click(at: clickPoint)
        try? await Task.sleep(nanoseconds: 240_000_000)
        pressKey(virtualKey: 0x00, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 80_000_000)
        await typeTextVisibly(query)
        if submit {
            try? await Task.sleep(nanoseconds: 120_000_000)
            pressReturn()
        }
        return true
    }

    func focusSearchFieldAndSubmit(query: String, keywords: [String]) async -> Bool {
        await focusSearchFieldAndType(query: query, keywords: keywords, submit: true)
    }

    func focusSearchFieldAndType(query: String, keywords: [String], submit: Bool) async -> Bool {
        guard hasAccessibilityPermission,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        if let searchElement = findSearchElement(in: appElement, keywords: keywords) {
            focus(element: searchElement)
            if setText(query, in: searchElement) {
                if submit {
                    pressReturn()
                }
                return true
            }

            clickCenter(of: searchElement)
            try? await Task.sleep(nanoseconds: 180_000_000)
            await typeTextVisibly(query)
            if submit {
                pressReturn()
            }
            return true
        }

        return false
    }

    func commandLTypeURLAndSubmit(_ url: URL) {
        pressKey(virtualKey: 0x25, flags: .maskCommand)
        typeText(url.absoluteString)
        pressReturn()
    }

    func commandLTypeURLAndSubmitVisibly(_ url: URL) async {
        pressKey(virtualKey: 0x25, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await typeTextVisibly(url.absoluteString)
        try? await Task.sleep(nanoseconds: 80_000_000)
        pressReturn()
    }

    func typeText(_ text: String) {
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
            keyDownEvent?.keyboardSetUnicodeString(
                stringLength: characters.count,
                unicodeString: baseAddress
            )
            keyDownEvent?.post(tap: .cghidEventTap)

            let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            keyUpEvent?.keyboardSetUnicodeString(
                stringLength: characters.count,
                unicodeString: baseAddress
            )
            keyUpEvent?.post(tap: .cghidEventTap)
        }
    }

    func pressReturn() {
        pressKey(virtualKey: 0x24, flags: [])
    }

    func typeTextVisibly(_ text: String) async {
        for character in text {
            typeText(String(character))
            try? await Task.sleep(nanoseconds: 18_000_000)
        }
    }

    func moveMouse(to screenPoint: CGPoint) {
        CGWarpMouseCursorPosition(screenPoint)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(true))
    }

    func click(at screenPoint: CGPoint) {
        click(screenPoint: screenPoint)
    }

    func click(screenPoint: CGPoint) {
        let mouseDownEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        )
        mouseDownEvent?.post(tap: .cghidEventTap)

        let mouseUpEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        )
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    func doubleClick(screenPoint: CGPoint) {
        click(screenPoint: screenPoint)
        Thread.sleep(forTimeInterval: 0.08)
        click(screenPoint: screenPoint)
    }

    func rightClick(screenPoint: CGPoint) {
        let mouseDownEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseDown,
            mouseCursorPosition: screenPoint,
            mouseButton: .right
        )
        mouseDownEvent?.post(tap: .cghidEventTap)

        let mouseUpEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseUp,
            mouseCursorPosition: screenPoint,
            mouseButton: .right
        )
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    func scroll(deltaY: CGFloat) {
        let wheelDelta = Int32(deltaY)
        let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 1,
            wheel1: wheelDelta,
            wheel2: 0,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    func wait(milliseconds: Int) async {
        let clamped = max(0, min(milliseconds, 5_000))
        try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
    }

    func pressNamedKey(_ key: String) {
        let normalized = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyCode = Self.namedKeyCodes[normalized] else { return }
        pressKey(virtualKey: keyCode, flags: [])
    }

    func pressShortcut(_ keys: [String]) {
        let normalized = keys.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        var flags = CGEventFlags()
        if normalized.contains("command") || normalized.contains("cmd") {
            flags.insert(.maskCommand)
        }
        if normalized.contains("shift") {
            flags.insert(.maskShift)
        }
        if normalized.contains("option") || normalized.contains("alt") {
            flags.insert(.maskAlternate)
        }
        if normalized.contains("control") || normalized.contains("ctrl") {
            flags.insert(.maskControl)
        }

        guard let keyName = normalized.last(where: { !Self.modifierNames.contains($0) }),
              let keyCode = Self.namedKeyCodes[keyName] else {
            return
        }
        pressKey(virtualKey: keyCode, flags: flags)
    }

    func pressKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: true)
        keyDownEvent?.flags = flags
        keyDownEvent?.post(tap: .cghidEventTap)

        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: false)
        keyUpEvent?.flags = flags
        keyUpEvent?.post(tap: .cghidEventTap)
    }

    private static let modifierNames: Set<String> = [
        "command", "cmd", "shift", "option", "alt", "control", "ctrl"
    ]

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "return": 0x24, "enter": 0x24, "l": 0x25, "j": 0x26, "'": 0x27,
        "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D,
        "m": 0x2E, ".": 0x2F, "tab": 0x30, "space": 0x31, "`": 0x32,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E
    ]

    private func focusedWindowFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        guard let focusedWindowValue = copyAttribute(kAXFocusedWindowAttribute, from: appElement) else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement
        guard let positionValue = copyAttribute(kAXPositionAttribute, from: focusedWindow),
              let sizeValue = copyAttribute(kAXSizeAttribute, from: focusedWindow) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func fallbackFrontmostWindowFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return NSScreen.main?.visibleFrame
        }

        let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matchingWindowInfo = windowInfoList.first { windowInfo in
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostApplication.processIdentifier,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                return false
            }
            return windowInfo[kCGWindowBounds as String] != nil
        }

        guard let boundsDictionary = matchingWindowInfo?[kCGWindowBounds as String] as? [String: Any],
              let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return NSScreen.main?.visibleFrame
        }

        guard let containingScreen = NSScreen.screens.first(where: { screen in
            screen.frame.intersects(windowBounds)
        }) else {
            return windowBounds
        }

        let convertedY = containingScreen.frame.maxY - windowBounds.origin.y - windowBounds.height
        return CGRect(
            x: windowBounds.origin.x,
            y: convertedY,
            width: windowBounds.width,
            height: windowBounds.height
        )
    }

    private func focusedWindowTitle(for appElement: AXUIElement) -> String? {
        guard let focusedWindowValue = copyAttribute(kAXFocusedWindowAttribute, from: appElement) else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement
        return copyAttribute(kAXTitleAttribute, from: focusedWindow) as? String
    }

    private func findSearchElement(
        in rootElement: AXUIElement,
        keywords: [String]
    ) -> AXUIElement? {
        var queue: [AXUIElement] = [rootElement]
        var visitedCount = 0
        let maximumVisitedElements = 450

        while !queue.isEmpty && visitedCount < maximumVisitedElements {
            let element = queue.removeFirst()
            visitedCount += 1

            if isLikelySearchElement(element, keywords: keywords) {
                return element
            }

            queue.append(contentsOf: children(of: element))
        }

        return nil
    }

    private func isLikelySearchElement(_ element: AXUIElement, keywords: [String]) -> Bool {
        let role = copyAttribute(kAXRoleAttribute, from: element) as? String
        let subrole = copyAttribute(kAXSubroleAttribute, from: element) as? String
        let isTextInput = role == (kAXTextFieldRole as String)
            || role == "AXSearchField"
            || subrole == "AXSearchField"

        guard isTextInput else { return false }

        let searchableText = [
            copyAttribute(kAXTitleAttribute, from: element) as? String,
            copyAttribute(kAXDescriptionAttribute, from: element) as? String,
            copyAttribute("AXPlaceholderValue", from: element) as? String,
            copyAttribute(kAXHelpAttribute, from: element) as? String
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if searchableText.isEmpty {
            return true
        }

        return keywords.contains(where: { searchableText.contains($0.lowercased()) })
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let childElements = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else {
            return []
        }
        return childElements
    }

    private func focus(element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func setText(_ text: String, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    private func clickCenter(of element: AXUIElement) {
        guard let positionValue = copyAttribute(kAXPositionAttribute, from: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, from: element) else {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            return
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        let centerPoint = CGPoint(
            x: position.x + (size.width / 2),
            y: position.y + (size.height / 2)
        )

        moveMouse(to: centerPoint)
        click(at: centerPoint)
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}
