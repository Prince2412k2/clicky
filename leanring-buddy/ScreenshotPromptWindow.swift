import AppKit
import SwiftUI

private final class ScreenshotPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScreenshotAnnotationStroke: Identifiable {
    let id = UUID()
    var normalizedPoints: [CGPoint]
}

@MainActor
final class ScreenshotPromptWindowManager {
    private var window: NSPanel?
    private let onSubmit: (String, CompanionScreenCapture) -> Void

    init(onSubmit: @escaping (String, CompanionScreenCapture) -> Void) {
        self.onSubmit = onSubmit
    }

    func show(screenCapture: CompanionScreenCapture) {
        close()

        guard let screenshotImage = NSImage(data: screenCapture.imageData) else { return }

        let promptView = ScreenshotPromptView(
            screenshotImage: screenshotImage,
            onCancel: { [weak self] in self?.close() },
            onSubmit: { [weak self] prompt, annotationStrokes in
                guard let self else { return }
                let annotatedCapture = self.captureByApplyingAnnotations(
                    annotationStrokes,
                    to: screenCapture,
                    screenshotImage: screenshotImage
                )
                self.close()
                self.onSubmit(prompt, annotatedCapture)
            }
        )

        let hostingView = NSHostingView(rootView: promptView)
        let panel = ScreenshotPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    private func captureByApplyingAnnotations(
        _ annotationStrokes: [ScreenshotAnnotationStroke],
        to screenCapture: CompanionScreenCapture,
        screenshotImage: NSImage
    ) -> CompanionScreenCapture {
        guard !annotationStrokes.isEmpty else { return screenCapture }

        let imageSize = NSSize(
            width: screenCapture.screenshotWidthInPixels,
            height: screenCapture.screenshotHeightInPixels
        )
        let annotatedImage = NSImage(size: imageSize)
        annotatedImage.lockFocus()
        screenshotImage.draw(in: NSRect(origin: .zero, size: imageSize))

        NSColor.systemRed.setStroke()
        for annotationStroke in annotationStrokes where annotationStroke.normalizedPoints.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = max(4, imageSize.width / 300)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            for (pointIndex, normalizedPoint) in annotationStroke.normalizedPoints.enumerated() {
                let imagePoint = NSPoint(
                    x: normalizedPoint.x * imageSize.width,
                    y: (1 - normalizedPoint.y) * imageSize.height
                )
                if pointIndex == 0 {
                    path.move(to: imagePoint)
                } else {
                    path.line(to: imagePoint)
                }
            }
            path.stroke()
        }
        annotatedImage.unlockFocus()

        guard let imageData = annotatedImage.tiffRepresentation,
              let bitmapRepresentation = NSBitmapImageRep(data: imageData),
              let jpegData = bitmapRepresentation.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.9]
              ) else {
            return screenCapture
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: screenCapture.label + " (user annotations are marked in red)",
            isCursorScreen: screenCapture.isCursorScreen,
            displayWidthInPoints: screenCapture.displayWidthInPoints,
            displayHeightInPoints: screenCapture.displayHeightInPoints,
            displayFrame: screenCapture.displayFrame,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )
    }
}

private struct ScreenshotPromptView: View {
    let screenshotImage: NSImage
    let onCancel: () -> Void
    let onSubmit: (String, [ScreenshotAnnotationStroke]) -> Void

    @State private var prompt = ""
    @State private var annotationStrokes: [ScreenshotAnnotationStroke] = []
    @State private var activeStroke = ScreenshotAnnotationStroke(normalizedPoints: [])
    @FocusState private var isPromptFocused: Bool

    private var screenshotAspectRatio: CGFloat {
        max(screenshotImage.size.width / max(screenshotImage.size.height, 1), 0.1)
    }

    private var displayedScreenshotSize: CGSize {
        let maximumWidth: CGFloat = 900
        let maximumHeight: CGFloat = 560
        if maximumWidth / screenshotAspectRatio <= maximumHeight {
            return CGSize(width: maximumWidth, height: maximumWidth / screenshotAspectRatio)
        }
        return CGSize(width: maximumHeight * screenshotAspectRatio, height: maximumHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            screenshotCanvas

            HStack(spacing: 10) {
                Button {
                    annotationStrokes.removeAll()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear annotations")
                .pointerCursor()

                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)

                TextField("Ask anything about this window…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isPromptFocused)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor()
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        }
        .padding(20)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { isPromptFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private var screenshotCanvas: some View {
        ZStack {
            Image(nsImage: screenshotImage)
                .resizable()
                .interpolation(.high)
                .frame(width: displayedScreenshotSize.width, height: displayedScreenshotSize.height)

            Canvas { context, canvasSize in
                for annotationStroke in annotationStrokes + [activeStroke] {
                    guard let firstPoint = annotationStroke.normalizedPoints.first else { continue }
                    var path = Path()
                    path.move(to: denormalizedPoint(firstPoint, canvasSize: canvasSize))
                    for normalizedPoint in annotationStroke.normalizedPoints.dropFirst() {
                        path.addLine(to: denormalizedPoint(normalizedPoint, canvasSize: canvasSize))
                    }
                    context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: displayedScreenshotSize.width, height: displayedScreenshotSize.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragValue in
                        let normalizedPoint = CGPoint(
                            x: min(max(dragValue.location.x / displayedScreenshotSize.width, 0), 1),
                            y: min(max(dragValue.location.y / displayedScreenshotSize.height, 0), 1)
                        )
                        activeStroke.normalizedPoints.append(normalizedPoint)
                    }
                    .onEnded { _ in
                        if activeStroke.normalizedPoints.count > 1 {
                            annotationStrokes.append(activeStroke)
                        }
                        activeStroke = ScreenshotAnnotationStroke(normalizedPoints: [])
                        isPromptFocused = true
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private func denormalizedPoint(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
    }

    private func submit() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        onSubmit(trimmedPrompt, annotationStrokes)
    }
}
