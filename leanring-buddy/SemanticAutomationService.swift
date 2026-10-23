import AppKit
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

struct OpenClickySemanticElement {
    let id: String
    let bounds: CGRect
}

struct OpenClickySemanticSnapshot {
    let snapshotID: String
    let applicationName: String
    let elementsByID: [String: OpenClickySemanticElement]
    let compactDescription: String
    let stateFingerprint: Set<String>
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
        let actionableElements = result.elements.all.filter(\.isActionable)
        let elementsByID = Dictionary(
            actionableElements.map {
                ($0.id, OpenClickySemanticElement(id: $0.id, bounds: $0.bounds))
            },
            uniquingKeysWith: { firstElement, _ in firstElement }
        )
        let sortedElements = actionableElements.sorted { firstElement, secondElement in
            if firstElement.bounds.minY == secondElement.bounds.minY {
                return firstElement.bounds.minX < secondElement.bounds.minX
            }
            return firstElement.bounds.minY < secondElement.bounds.minY
        }.prefix(140)
        let rows = sortedElements.map { element in
            let label = element.label?.replacingOccurrences(of: "\n", with: " ") ?? ""
            let value = element.value?.replacingOccurrences(of: "\n", with: " ") ?? ""
            let bounds = element.bounds
            return "[\(element.id)] \(element.type.rawValue) label=\(String(label.prefix(100))) "
                + "value=\(String(value.prefix(80))) frame="
                + "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
        }
        let fingerprint = Set(result.elements.all.map { element in
            "\(element.type.rawValue)|\(element.label ?? "")|\(element.value ?? "")|\(element.isSelected.map(String.init) ?? "")"
        })
        return OpenClickySemanticSnapshot(
            snapshotID: result.snapshotId,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "the active app",
            elementsByID: elementsByID,
            compactDescription: "Accessibility snapshot for \(application.localizedName ?? "the active app"):\n"
                + rows.joined(separator: "\n"),
            stateFingerprint: fingerprint
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
