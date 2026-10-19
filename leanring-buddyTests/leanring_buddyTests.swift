//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

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

}
