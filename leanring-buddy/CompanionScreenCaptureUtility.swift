//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ImageIO
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let frozenDisplayImageData: Data?
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

        let maxDimension = 1280
        let frozenDisplayConfiguration = SCStreamConfiguration()
        let nativeDisplayWidth = CGDisplayPixelsWide(display.displayID)
        let nativeDisplayHeight = CGDisplayPixelsHigh(display.displayID)
        frozenDisplayConfiguration.width = nativeDisplayWidth > 0
            ? nativeDisplayWidth
            : display.width
        frozenDisplayConfiguration.height = nativeDisplayHeight > 0
            ? nativeDisplayHeight
            : display.height

        // Keep the frozen launcher lossless and Retina-sharp without sending
        // that much larger image to the selected model.
        let frozenDisplayImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: frozenDisplayConfiguration
        )

        guard let frozenDisplayImageData = NSBitmapImageRep(cgImage: frozenDisplayImage)
                .representation(using: .png, properties: [:]),
              let imageSource = CGImageSourceCreateWithData(
                frozenDisplayImageData as CFData,
                nil
              ),
              let analysisImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension
                ] as CFDictionary
              ),
              let jpegData = NSBitmapImageRep(cgImage: analysisImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode the screen capture"])
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            frozenDisplayImageData: frozenDisplayImageData,
            label: "screen containing the pointer",
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: analysisImage.width,
            screenshotHeightInPixels: analysisImage.height
        )
    }
}
