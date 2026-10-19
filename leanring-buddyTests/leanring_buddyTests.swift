//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
import Foundation
@testable import OpenClicky

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func convertsPrimaryDisplayWindowCoordinatesToAppKitCoordinates() {
        let convertedFrame = CompanionScreenCaptureUtility.convertCoreGraphicsWindowFrameToAppKit(
            CGRect(x: 100, y: 80, width: 900, height: 600),
            screenCaptureDisplayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )

        #expect(convertedFrame == CGRect(x: 100, y: 302, width: 900, height: 600))
    }

    @Test func convertsSecondaryDisplayWindowCoordinatesToAppKitCoordinates() {
        let convertedFrame = CompanionScreenCaptureUtility.convertCoreGraphicsWindowFrameToAppKit(
            CGRect(x: 1600, y: 100, width: 800, height: 500),
            screenCaptureDisplayFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            appKitScreenFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1080)
        )

        #expect(convertedFrame == CGRect(x: 1600, y: 382, width: 800, height: 500))
    }

    @Test func parsesPointingCoordinatesAndRemovesTheTag() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "Open settings. [POINT:320,180:settings button:screen2]"
        )

        #expect(result.spokenText == "Open settings.")
        #expect(result.coordinate == CGPoint(x: 320, y: 180))
        #expect(result.elementLabel == "settings button")
        #expect(result.screenNumber == 2)
    }

    @Test func parsesNoPointingResponse() {
        let result = CompanionManager.parsePointingCoordinates(from: "Nothing to point at. [POINT:none]")

        #expect(result.spokenText == "Nothing to point at.")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
        #expect(result.screenNumber == nil)
    }

    @Test func parsesMultipleTeachingAnnotationsAndRemovesTags() {
        let result = ScreenAnnotationParser.parse(
            from: "Open the inspector, then check this section. [POINT:none]\n[DRAW:arrow:100,120,460,260:open inspector]\n[DRAW:box:500,200,220,140:settings area]"
        )

        #expect(result.responseText == "Open the inspector, then check this section. [POINT:none]")
        #expect(result.annotations.count == 2)
        #expect(result.annotations[0].kind == .arrow)
        #expect(result.annotations[0].coordinates == [100, 120, 460, 260])
        #expect(result.annotations[0].label == "open inspector")
        #expect(result.annotations[1].kind == .box)
    }

    @Test func ignoresMalformedTeachingAnnotations() {
        let result = ScreenAnnotationParser.parse(
            from: "Use this control. [DRAW:arrow:10,20:missing coordinates]"
        )

        #expect(result.responseText == "Use this control.")
        #expect(result.annotations.isEmpty)
    }

    @Test func convertsScreenshotPixelsIntoGlobalWindowCoordinates() {
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test window",
            isCursorScreen: true,
            displayWidthInPoints: 800,
            displayHeightInPoints: 600,
            displayFrame: CGRect(x: 200, y: 100, width: 800, height: 600),
            screenshotWidthInPixels: 1600,
            screenshotHeightInPixels: 1200
        )

        let globalLocation = CompanionManager.convertScreenshotPointToGlobalAppKit(
            CGPoint(x: 800, y: 300),
            screenCapture: screenCapture
        )

        #expect(globalLocation == CGPoint(x: 600, y: 550))
    }

}
