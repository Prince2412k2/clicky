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

    @Test func parsesGuidedWalkthroughContinuation() {
        let result = GuidedSessionParser.parse(
            from: "Click the shader tab. [GUIDE:continue]\n[DRAW:pointer:200,100:shader tab]"
        )

        #expect(result.directive == .continueGuiding)
        #expect(result.responseText.contains("Click the shader tab."))
        #expect(result.responseText.contains("[DRAW:pointer:200,100:shader tab]"))
    }

    @Test func parsesGuidedWalkthroughCompletion() {
        let result = GuidedSessionParser.parse(from: "Your texture is connected. [GUIDE:done]")

        #expect(result.directive == .done)
        #expect(result.responseText == "Your texture is connected.")
    }

    @Test func parsesApprovedClickRequestAndRemovesActionTag() {
        let result = ComputerActionParser.parse(
            from: "I can open that panel for you. [ACTION:click:420,180:open shader panel] [GUIDE:continue]"
        )

        #expect(result.clickAction?.screenshotLocation == CGPoint(x: 420, y: 180))
        #expect(result.clickAction?.label == "open shader panel")
        #expect(result.responseText.contains("I can open that panel for you."))
        #expect(result.responseText.contains("[GUIDE:continue]"))
        #expect(!result.responseText.contains("[ACTION:"))
    }

}
