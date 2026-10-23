import AppKit
import Foundation
import PeekabooAutomationKit

struct OpenClickySemanticSnapshot {
    let snapshotID: String
    let applicationName: String
    let elementsByID: [String: DetectedElement]

    var compactDescription: String {
        let actionableElements = elementsByID.values
            .filter(\.isActionable)
            .sorted { firstElement, secondElement in
                if firstElement.bounds.minY == secondElement.bounds.minY {
                    return firstElement.bounds.minX < secondElement.bounds.minX
                }
                return firstElement.bounds.minY < secondElement.bounds.minY
            }
            .prefix(140)

        let rows = actionableElements.map { element in
            let label = element.label?.replacingOccurrences(of: "\n", with: " ") ?? ""
            let value = element.value?.replacingOccurrences(of: "\n", with: " ") ?? ""
            let bounds = element.bounds
            return "[\(element.id)] \(element.type.rawValue) label=\(String(label.prefix(100))) "
                + "value=\(String(value.prefix(80))) frame="
                + "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
        }
        return "Accessibility snapshot for \(applicationName):\n" + rows.joined(separator: "\n")
    }

    var stateFingerprint: Set<String> {
        Set(elementsByID.values.map { element in
            "\(element.type.rawValue)|\(element.label ?? "")|\(element.value ?? "")|\(element.isSelected.map(String.init) ?? "")"
        })
    }
}

@MainActor
final class SemanticAutomationService {
    private let snapshotManager = InMemorySnapshotManager()
    private lazy var automationService = UIAutomationService(
        snapshotManager: snapshotManager,
        feedbackClient: NoopAutomationFeedbackClient()
    )

    func captureFrontmostSnapshot() async throws -> OpenClickySemanticSnapshot {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw NSError(
                domain: "OpenClickySemanticAutomation",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No target application is active"]
            )
        }

        let context = WindowContext(
            applicationName: application.localizedName,
            applicationBundleId: application.bundleIdentifier,
            applicationBundlePath: application.bundleURL?.path,
            applicationExecutablePath: application.executableURL?.path,
            applicationProcessId: application.processIdentifier,
            shouldFocusWebContent: false,
            includeMenuBarElements: true,
            requiresFreshAccessibilityTree: true,
            accessibilityTimeoutSeconds: 8,
            allowApplicationScopedAccessibilityFallback: true
        )
        let result = try await automationService.inspectAccessibilityTree(windowContext: context)
        let elementsByID = Dictionary(
            result.elements.all.map { ($0.id, $0) },
            uniquingKeysWith: { firstElement, _ in firstElement }
        )
        return OpenClickySemanticSnapshot(
            snapshotID: result.snapshotId,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "the active app",
            elementsByID: elementsByID
        )
    }

    func clickElement(elementID: String, snapshotID: String) async throws {
        try await automationService.click(
            target: .elementId(elementID),
            clickType: .single,
            snapshotId: snapshotID
        )
    }
}
