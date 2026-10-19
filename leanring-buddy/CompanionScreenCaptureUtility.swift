//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
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

    static func captureFrontmostWindowAsJPEG() async throws -> CompanionScreenCapture {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No frontmost application is available"]
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidateWindows = content.windows.filter { window in
            window.owningApplication?.processID == frontmostApplication.processIdentifier
                && window.isOnScreen
                && window.frame.width >= 160
                && window.frame.height >= 120
        }

        guard let frontmostWindow = candidateWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "The frontmost app has no capturable window"]
            )
        }

        let configuration = SCStreamConfiguration()
        let maximumDimension = 1440
        let aspectRatio = frontmostWindow.frame.width / frontmostWindow.frame.height
        if frontmostWindow.frame.width >= frontmostWindow.frame.height {
            configuration.width = maximumDimension
            configuration.height = max(1, Int(CGFloat(maximumDimension) / aspectRatio))
        } else {
            configuration.height = maximumDimension
            configuration.width = max(1, Int(CGFloat(maximumDimension) * aspectRatio))
        }
        configuration.showsCursor = false

        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: frontmostWindow),
            configuration: configuration
        )
        guard let jpegData = NSBitmapImageRep(cgImage: capturedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "The captured window could not be encoded"]
            )
        }

        let windowFrame = frontmostWindow.frame
        let targetDisplay = content.displays.max { firstDisplay, secondDisplay in
            firstDisplay.frame.intersection(windowFrame).area
                < secondDisplay.frame.intersection(windowFrame).area
        }
        let targetNSScreen = targetDisplay.flatMap { display in
            NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == display.displayID
            }
        }
        let appKitWindowFrame: CGRect
        if let targetDisplay, let targetNSScreen {
            appKitWindowFrame = convertCoreGraphicsWindowFrameToAppKit(
                windowFrame,
                screenCaptureDisplayFrame: targetDisplay.frame,
                appKitScreenFrame: targetNSScreen.frame
            )
        } else {
            appKitWindowFrame = targetNSScreen?.frame ?? NSScreen.main?.frame ?? windowFrame
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "frontmost window in \(frontmostApplication.localizedName ?? "the active app")",
            isCursorScreen: true,
            displayWidthInPoints: Int(windowFrame.width),
            displayHeightInPoints: Int(windowFrame.height),
            displayFrame: appKitWindowFrame,
            screenshotWidthInPixels: capturedImage.width,
            screenshotHeightInPixels: capturedImage.height
        )
    }

    static func convertCoreGraphicsWindowFrameToAppKit(
        _ windowFrame: CGRect,
        screenCaptureDisplayFrame: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGRect {
        let displayLocalX = windowFrame.minX - screenCaptureDisplayFrame.minX
        let displayLocalYFromTop = windowFrame.minY - screenCaptureDisplayFrame.minY
        return CGRect(
            x: appKitScreenFrame.minX + displayLocalX,
            y: appKitScreenFrame.maxY - displayLocalYFromTop - windowFrame.height,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    /// Captures only the display containing the pointer. Avoiding unrelated
    /// displays minimizes the screen content sent with a voice prompt.
    static func captureScreenContainingPointerAsJPEG() async throws -> CompanionScreenCapture {
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

        guard let display = content.displays.first(where: { display in
            let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
            return frame.contains(mouseLocation)
        }) ?? content.displays.first else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
        // displayFrame is in the same coordinate system as NSEvent.mouseLocation
        // and the overlay window's screenFrame in BlueCursorView.
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
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode the screen capture"])
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "screen containing the pointer",
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
