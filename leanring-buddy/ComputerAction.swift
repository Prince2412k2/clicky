import AppKit
import CoreGraphics
import SwiftUI

struct ParsedComputerClickAction: Equatable {
    let screenshotLocation: CGPoint
    let label: String
}

struct ComputerActionParseResult: Equatable {
    let responseText: String
    let clickAction: ParsedComputerClickAction?
}

enum ComputerActionParser {
    static func parse(from responseText: String) -> ComputerActionParseResult {
        let pattern = #"\[ACTION:click:(\d+(?:\.\d+)?),(\d+(?:\.\d+)?):([^\]]+)\]"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return ComputerActionParseResult(responseText: responseText, clickAction: nil)
        }
        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        guard let match = regularExpression.firstMatch(in: responseText, range: responseRange),
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let labelRange = Range(match.range(at: 3), in: responseText),
              let xCoordinate = Double(responseText[xRange]),
              let yCoordinate = Double(responseText[yRange]) else {
            let cleanedResponse = regularExpression
                .stringByReplacingMatches(in: responseText, range: responseRange, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ComputerActionParseResult(responseText: cleanedResponse, clickAction: nil)
        }

        let cleanedResponse = regularExpression
            .stringByReplacingMatches(in: responseText, range: responseRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ComputerActionParseResult(
            responseText: cleanedResponse,
            clickAction: ParsedComputerClickAction(
                screenshotLocation: CGPoint(x: xCoordinate, y: yCoordinate),
                label: String(responseText[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}

struct PendingComputerClickAction {
    let appKitLocation: CGPoint
    let label: String
    let targetApplication: NSRunningApplication?
}

@MainActor
enum ComputerClickExecutor {
    static func perform(_ action: PendingComputerClickAction) async throws {
        action.targetApplication?.activate(options: [])
        try await Task.sleep(for: .milliseconds(250))
        let coreGraphicsLocation = convertAppKitPointToCoreGraphics(action.appKitLocation)

        guard let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: coreGraphicsLocation,
            mouseButton: .left
        ), let mouseDownEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: coreGraphicsLocation,
            mouseButton: .left
        ), let mouseUpEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: coreGraphicsLocation,
            mouseButton: .left
        ) else {
            throw NSError(
                domain: "OpenClickyComputerAction",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the approved click event"]
            )
        }

        moveEvent.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(120))
        mouseDownEvent.post(tap: .cghidEventTap)
        mouseUpEvent.post(tap: .cghidEventTap)
    }

    static func convertAppKitPointToCoreGraphics(_ appKitPoint: CGPoint) -> CGPoint {
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }),
              let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else {
            return appKitPoint
        }
        let coreGraphicsDisplayFrame = CGDisplayBounds(displayID)
        return CGPoint(
            x: coreGraphicsDisplayFrame.minX + appKitPoint.x - targetScreen.frame.minX,
            y: coreGraphicsDisplayFrame.minY + targetScreen.frame.maxY - appKitPoint.y
        )
    }
}

private final class ComputerActionApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ComputerActionApprovalWindowManager {
    private var panel: NSPanel?

    func show(
        action: PendingComputerClickAction,
        allowsWalkthroughApproval: Bool,
        onAllowOnce: @escaping () -> Void,
        onAllowWalkthrough: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        let view = ComputerActionApprovalView(
            actionLabel: action.label,
            allowsWalkthroughApproval: allowsWalkthroughApproval,
            onAllowOnce: onAllowOnce,
            onAllowWalkthrough: onAllowWalkthrough,
            onCancel: onCancel
        )
        let hostingView = NSHostingView(rootView: view)
        let panelSize = NSSize(width: 330, height: 152)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(action.appKitLocation) })
            ?? NSScreen.main
        guard let targetScreen else { return }
        let panelFrame = NSRect(
            x: targetScreen.visibleFrame.maxX - panelSize.width - 20,
            y: targetScreen.visibleFrame.maxY - panelSize.height - 20,
            width: panelSize.width,
            height: panelSize.height
        )
        let actionPanel = ComputerActionApprovalPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        actionPanel.contentView = hostingView
        actionPanel.isFloatingPanel = true
        actionPanel.level = .screenSaver
        actionPanel.isOpaque = false
        actionPanel.backgroundColor = .clear
        actionPanel.hasShadow = true
        actionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        actionPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = actionPanel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private struct ComputerActionApprovalView: View {
    let actionLabel: String
    let allowsWalkthroughApproval: Bool
    let onAllowOnce: () -> Void
    let onAllowWalkthrough: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow OpenClicky to click?")
                        .font(.system(size: 13, weight: .semibold))
                    Text(actionLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Allow Once", action: onAllowOnce)
                if allowsWalkthroughApproval {
                    Button("Allow Walkthrough", action: onAllowWalkthrough)
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330, height: 152)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}
