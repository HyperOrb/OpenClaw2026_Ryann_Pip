//
//  CompanionScreenCaptureUtility.swift
//  pippy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        var lastError: Error?

        // Path 1: ScreenCaptureKit (modern, preferred).
        do {
            let captures = try await captureAllScreensWithScreenCaptureKit()
            if !captures.isEmpty {
                persistConfirmedPermissionFlag()
                return captures
            }
        } catch {
            logScreenCaptureFailure(stage: "ScreenCaptureKit", error: error)
            lastError = error
            if Self.isLikelyPermissionError(error) {
                clearConfirmedPermissionFlag()
                throw error
            }
        }

        // Path 2: In-process CGDisplayCreateImage. Same TCC requirement
        // as ScreenCaptureKit, but routes through a different system code
        // path that occasionally succeeds when SCShareableContent throws
        // a transient error.
        if let cgCaptures = captureAllScreensWithCGWindowList(), !cgCaptures.isEmpty {
            persistConfirmedPermissionFlag()
            return cgCaptures
        }
        print("⚠️ CGDisplayCreateImage returned nil for all displays (TCC likely denied)")

        // Path 3: `/usr/sbin/screencapture` subprocess. Last resort. Note:
        // when the app lacks Screen Recording permission this tool prints
        // "could not create image from display" to stderr, which we silence
        // by routing stderr/stdout to /dev/null.
        if let subprocessCaptures = captureAllScreensWithScreencaptureSubprocess(),
           !subprocessCaptures.isEmpty {
            persistConfirmedPermissionFlag()
            return subprocessCaptures
        }
        print("⚠️ screencapture subprocess fallback also failed")

        // Every path failed — emit a one-shot diagnostic dump and treat
        // this as a permission problem so the caller can surface a clear
        // remediation message.
        emitDiagnosticDumpIfNeeded()
        clearConfirmedPermissionFlag()
        let underlyingMessage = lastError.map { " (\($0.localizedDescription))" } ?? ""
        throw NSError(
            domain: "CompanionScreenCapture",
            code: -3,
            userInfo: [
                NSLocalizedDescriptionKey: "Screen Recording permission denied" + underlyingMessage
            ]
        )
    }

    private static func logScreenCaptureFailure(stage: String, error: Error) {
        let ns = error as NSError
        print("⚠️ \(stage) capture failed:")
        print("   • localizedDescription: \(ns.localizedDescription)")
        print("   • domain: \(ns.domain)  code: \(ns.code)")
        if !ns.userInfo.isEmpty {
            print("   • userInfo: \(ns.userInfo)")
        }
    }

    /// Prints a one-time diagnostic snapshot the first time every capture
    /// path fails. Helps diagnose whether the issue is a missing TCC grant,
    /// a stale grant pointing at a different bundle path, or something else.
    private static var hasEmittedDiagnosticDump = false
    private static func emitDiagnosticDumpIfNeeded() {
        guard !hasEmittedDiagnosticDump else { return }
        hasEmittedDiagnosticDump = true
        printDiagnosticDump(reason: "All capture paths failed")
    }

    /// Public entry point invoked at app startup so we always see the
    /// current TCC state in the console regardless of whether the user
    /// has triggered a capture attempt yet.
    static func logStartupDiagnostic() {
        printDiagnosticDump(reason: "Startup")
        // Mark as emitted so we don't repeat the same dump again on the
        // first capture failure.
        hasEmittedDiagnosticDump = true
    }

    private static func printDiagnosticDump(reason: String) {
        let bundleID = Bundle.main.bundleIdentifier ?? "(unknown)"
        let bundlePath = Bundle.main.bundlePath
        let preflight = CGPreflightScreenCaptureAccess()
        let mainDisplayCapture = CGDisplayCreateImage(CGMainDisplayID()) != nil
        let cachedFlag = UserDefaults.standard.bool(
            forKey: "hasPreviouslyConfirmedScreenRecordingPermission"
        )

        print("─── Pip Screen Capture Diagnostic (\(reason)) ───")
        print("Bundle ID:    \(bundleID)")
        print("Bundle path:  \(bundlePath)")
        print("CGPreflightScreenCaptureAccess: \(preflight)")
        print("CGDisplayCreateImage(main): \(mainDisplayCapture ? "succeeded" : "returned nil")")
        print("Cached confirmed-permission flag: \(cachedFlag)")
        print("NSScreen count: \(NSScreen.screens.count)")
        if !preflight {
            print("⚠️ macOS reports Screen Recording permission is NOT granted to this build.")
            print("Likely cause: the entry in System Settings is for a different bundle")
            print("path (Xcode rebuilds invalidate the TCC grant for each new DerivedData")
            print("location). Fix:")
            print("  1. Quit Pip completely")
            print("  2. In Finder, drag the built Pip.app out of:")
            print("     \(bundlePath)")
            print("     and into /Applications/")
            print("  3. Open System Settings → Privacy & Security → Screen Recording")
            print("  4. Remove EVERY existing Pip entry with the ‘-’ button")
            print("  5. Launch /Applications/Pip.app — when it prompts, grant permission")
            print("  6. Quit & relaunch when macOS asks")
            print("This makes the bundle path stable across rebuilds.")
        }
        print("──────────────────────────────────────────────────")
    }

    private static func persistConfirmedPermissionFlag() {
        UserDefaults.standard.set(
            true,
            forKey: "hasPreviouslyConfirmedScreenRecordingPermission"
        )
    }

    /// Removes the "previously confirmed" flag so the app stops bypassing
    /// the permission gate based on stale state. This is critical for the
    /// dev/Xcode workflow where rebuilding the app invalidates the TCC
    /// grant but the user-defaults flag persists.
    private static func clearConfirmedPermissionFlag() {
        UserDefaults.standard.removeObject(
            forKey: "hasPreviouslyConfirmedScreenRecordingPermission"
        )
    }

    private static func isLikelyPermissionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("tcc")
            || message.contains("declined")
            || message.contains("permission")
            || message.contains("not authorized")
            || message.contains("denied")
    }

    private static func captureAllScreensWithScreenCaptureKit() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in PipPetOverlayView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// In-process screen capture using `CGWindowListCreateImage`. Uses the
    /// same TCC grant as ScreenCaptureKit but routes through a different
    /// code path that occasionally succeeds when SCShareableContent throws
    /// a transient error.
    private static func captureAllScreensWithCGWindowList() -> [CompanionScreenCapture]? {
        let nsScreenByDisplayID = screenLookupByDisplayID()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let mouseLocation = NSEvent.mouseLocation
        let sortedScreens = screens.sorted { a, b in
            let aHasCursor = a.frame.contains(mouseLocation)
            let bHasCursor = b.frame.contains(mouseLocation)
            if aHasCursor != bHasCursor { return aHasCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []
        for (index, screen) in sortedScreens.enumerated() {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            // CGDisplayCreateImage takes a CGDirectDisplayID and returns
            // the full display image. Requires Screen Recording permission.
            guard let cgImage = CGDisplayCreateImage(displayID) else {
                return nil
            }
            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let displayFrame = nsScreenByDisplayID[displayID]?.frame ?? screen.frame
            let isCursorScreen = displayFrame.contains(mouseLocation)
            let screenLabel: String
            if sortedScreens.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(index + 1) of \(sortedScreens.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(index + 1) of \(sortedScreens.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: cgImage.width,
                screenshotHeightInPixels: cgImage.height
            ))
        }

        return capturedScreens.isEmpty ? nil : capturedScreens
    }

    /// Uses `/usr/sbin/screencapture` as a last-resort fallback. Stderr
    /// and stdout are routed to /dev/null so the system tool's TCC error
    /// message ("could not create image from display") never leaks into
    /// the agent log or Xcode console.
    private static func captureAllScreensWithScreencaptureSubprocess() -> [CompanionScreenCapture]? {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipScreenCapture-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
            let screenshotURL = temporaryDirectoryURL.appendingPathComponent("screen.jpg")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "jpg", screenshotURL.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: screenshotURL.path),
                  let image = NSImage(contentsOf: screenshotURL),
                  let imageData = try? Data(contentsOf: screenshotURL) else {
                return nil
            }

            let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
                ?? NSScreen.main?.frame
                ?? CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)

            return [
                CompanionScreenCapture(
                    imageData: imageData,
                    label: "user's screen (cursor is here)",
                    isCursorScreen: true,
                    displayWidthInPoints: Int(screenFrame.width),
                    displayHeightInPoints: Int(screenFrame.height),
                    displayFrame: screenFrame,
                    screenshotWidthInPixels: Int(image.size.width),
                    screenshotHeightInPixels: Int(image.size.height)
                )
            ]
        } catch {
            print("⚠️ screencapture fallback failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func screenLookupByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }
        return nsScreenByDisplayID
    }
}
