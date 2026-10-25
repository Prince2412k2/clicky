import AppKit
import SwiftUI

private final class ScreenshotPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var cancelHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

private enum ScreenshotAnnotationTool: String, CaseIterable, Identifiable {
    case pen
    case arrow
    case rectangle
    case ellipse
    case eraser

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .eraser: return "eraser"
        }
    }

    var accessibilityLabel: String {
        rawValue.capitalized
    }
}

private struct ScreenshotAnnotation: Identifiable {
    let id = UUID()
    let tool: ScreenshotAnnotationTool
    var normalizedPoints: [CGPoint]
}

@MainActor
final class ScreenshotPromptWindowManager {
    private var window: NSPanel?
    private var previouslyActiveApplication: NSRunningApplication?
    private let onSubmit: (String, CompanionScreenCapture) -> Void

    init(onSubmit: @escaping (String, CompanionScreenCapture) -> Void) {
        self.onSubmit = onSubmit
    }

    func show(
        screenCapture: CompanionScreenCapture,
        providerName: String,
        modelName: String
    ) {
        close(restorePreviousApplication: false)

        guard let screenshotImage = NSImage(
            data: screenCapture.frozenDisplayImageData ?? screenCapture.imageData
        ) else { return }
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.intersects(screenCapture.displayFrame)
        } ?? NSScreen.main
        guard let targetScreen else { return }
        OpenClickyDiagnostics.record("launcher.shown", metadata: [
            "analysisPixels": "\(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels)",
            "displayPoints": "\(screenCapture.displayWidthInPoints)x\(screenCapture.displayHeightInPoints)",
            "frozenBytes": screenCapture.frozenDisplayImageData?.count ?? 0
        ])

        let promptView = ScreenshotPromptView(
            screenshotImage: screenshotImage,
            providerName: providerName,
            modelName: modelName,
            onCancel: { [weak self] in self?.close() },
            onSubmit: { [weak self] prompt, annotations in
                guard let self else { return }
                OpenClickyDiagnostics.record("launcher.submitted", metadata: [
                    "annotations": annotations.count,
                    "promptCharacters": prompt.count
                ])
                let annotatedCapture = self.captureByApplyingAnnotations(
                    annotations,
                    to: screenCapture,
                    screenshotImage: screenshotImage
                )
                self.close()
                self.onSubmit(prompt, annotatedCapture)
            }
        )

        let hostingView = NSHostingView(rootView: promptView)
        hostingView.frame = NSRect(origin: .zero, size: targetScreen.frame.size)
        let panel = ScreenshotPromptPanel(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.cancelHandler = { [weak self] in self?.close() }
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.setFrame(targetScreen.frame, display: true)
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close(restorePreviousApplication: Bool = true) {
        if window != nil {
            OpenClickyDiagnostics.record("launcher.closed", metadata: [
                "restorePreviousApplication": restorePreviousApplication
            ])
        }
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        if restorePreviousApplication {
            previouslyActiveApplication?.activate(options: [])
        }
        previouslyActiveApplication = nil
    }

    private func captureByApplyingAnnotations(
        _ annotations: [ScreenshotAnnotation],
        to screenCapture: CompanionScreenCapture,
        screenshotImage: NSImage
    ) -> CompanionScreenCapture {
        guard !annotations.isEmpty else {
            return CompanionScreenCapture(
                imageData: screenCapture.imageData,
                frozenDisplayImageData: nil,
                label: screenCapture.label,
                isCursorScreen: screenCapture.isCursorScreen,
                displayWidthInPoints: screenCapture.displayWidthInPoints,
                displayHeightInPoints: screenCapture.displayHeightInPoints,
                displayFrame: screenCapture.displayFrame,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
            )
        }

        let imageSize = NSSize(
            width: screenCapture.screenshotWidthInPixels,
            height: screenCapture.screenshotHeightInPixels
        )
        let annotatedImage = NSImage(size: imageSize)
        annotatedImage.lockFocus()
        screenshotImage.draw(in: NSRect(origin: .zero, size: imageSize))

        NSColor.systemRed.setStroke()
        for annotation in annotations {
            draw(annotation: annotation, imageSize: imageSize)
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
            frozenDisplayImageData: nil,
            label: screenCapture.label + " (user annotations are marked in red)",
            isCursorScreen: screenCapture.isCursorScreen,
            displayWidthInPoints: screenCapture.displayWidthInPoints,
            displayHeightInPoints: screenCapture.displayHeightInPoints,
            displayFrame: screenCapture.displayFrame,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )
    }

    private func draw(annotation: ScreenshotAnnotation, imageSize: NSSize) {
        guard let firstPoint = annotation.normalizedPoints.first else { return }
        let path = NSBezierPath()
        path.lineWidth = max(4, imageSize.width / 300)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch annotation.tool {
        case .pen:
            path.move(to: imagePoint(firstPoint, imageSize: imageSize))
            for normalizedPoint in annotation.normalizedPoints.dropFirst() {
                path.line(to: imagePoint(normalizedPoint, imageSize: imageSize))
            }
        case .arrow:
            guard let lastPoint = annotation.normalizedPoints.last else { return }
            let startPoint = imagePoint(firstPoint, imageSize: imageSize)
            let endPoint = imagePoint(lastPoint, imageSize: imageSize)
            path.move(to: startPoint)
            path.line(to: endPoint)
            appendArrowhead(to: path, startPoint: startPoint, endPoint: endPoint, imageSize: imageSize)
        case .rectangle, .ellipse:
            guard let lastPoint = annotation.normalizedPoints.last else { return }
            let annotationRect = imageRect(from: firstPoint, to: lastPoint, imageSize: imageSize)
            if annotation.tool == .rectangle {
                path.appendRoundedRect(annotationRect, xRadius: 10, yRadius: 10)
            } else {
                path.appendOval(in: annotationRect)
            }
        case .eraser:
            return
        }
        path.stroke()
    }

    private func imagePoint(_ normalizedPoint: CGPoint, imageSize: NSSize) -> NSPoint {
        NSPoint(
            x: normalizedPoint.x * imageSize.width,
            y: (1 - normalizedPoint.y) * imageSize.height
        )
    }

    private func imageRect(from firstPoint: CGPoint, to lastPoint: CGPoint, imageSize: NSSize) -> NSRect {
        let minimumX = min(firstPoint.x, lastPoint.x)
        let maximumX = max(firstPoint.x, lastPoint.x)
        let minimumY = min(firstPoint.y, lastPoint.y)
        let maximumY = max(firstPoint.y, lastPoint.y)
        return NSRect(
            x: minimumX * imageSize.width,
            y: (1 - maximumY) * imageSize.height,
            width: max((maximumX - minimumX) * imageSize.width, 8),
            height: max((maximumY - minimumY) * imageSize.height, 8)
        )
    }

    private func appendArrowhead(
        to path: NSBezierPath,
        startPoint: NSPoint,
        endPoint: NSPoint,
        imageSize: NSSize
    ) {
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let arrowheadLength = max(imageSize.width / 55, 18)
        let arrowheadAngle = CGFloat.pi / 6
        let firstArrowheadPoint = NSPoint(
            x: endPoint.x - arrowheadLength * cos(angle - arrowheadAngle),
            y: endPoint.y - arrowheadLength * sin(angle - arrowheadAngle)
        )
        let secondArrowheadPoint = NSPoint(
            x: endPoint.x - arrowheadLength * cos(angle + arrowheadAngle),
            y: endPoint.y - arrowheadLength * sin(angle + arrowheadAngle)
        )
        path.move(to: firstArrowheadPoint)
        path.line(to: endPoint)
        path.line(to: secondArrowheadPoint)
    }
}

private struct ScreenshotPromptView: View {
    let screenshotImage: NSImage
    let providerName: String
    let modelName: String
    let onCancel: () -> Void
    let onSubmit: (String, [ScreenshotAnnotation]) -> Void

    @State private var prompt = ""
    @State private var selectedTool: ScreenshotAnnotationTool?
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var activeAnnotation: ScreenshotAnnotation?
    @State private var isAnnotationPaletteVisible = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: screenshotImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .ignoresSafeArea()

            annotationCanvas

            launcherControls
                .padding(.top, 34)
        }
        .onAppear {
            // Focus after AppKit finishes making the borderless panel key.
            // Setting FocusState synchronously races panel activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                isPromptFocused = true
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private var launcherControls: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: 34, height: 34)
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    TextField("Ask anything about this screen…", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .medium))
                        .focused($isPromptFocused)
                        .onSubmit(submit)

                    annotationToggleButton
                    closeButton
                    submitButton
                }
                .padding(.horizontal, 12)
                .frame(height: 56)

                Divider()
                    .opacity(0.45)
                    .padding(.horizontal, 14)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(providerName)
                        .fontWeight(.medium)
                    Text("·")
                    Text(modelName)
                        .lineLimit(1)
                    Spacer()
                    Text("Enter to send")
                    Text("·")
                    Text("Esc to close")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(height: 25)
            }
            .frame(width: 680)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.38), radius: 24, y: 10)

            if isAnnotationPaletteVisible {
                annotationPalette
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: isAnnotationPaletteVisible)
    }

    private var annotationToggleButton: some View {
        Button {
            isAnnotationPaletteVisible.toggle()
            selectedTool = isAnnotationPaletteVisible ? (selectedTool ?? .arrow) : nil
            if !isAnnotationPaletteVisible {
                isPromptFocused = true
            }
        } label: {
            Image(systemName: isAnnotationPaletteVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .background(
                    isAnnotationPaletteVisible ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAnnotationPaletteVisible ? Color.accentColor : Color.secondary)
        .help("Annotate screen")
        .pointerCursor()
    }

    private var closeButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .pointerCursor()
    }

    private var submitButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    canSubmit ? Color.accentColor : Color.secondary.opacity(0.28),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .help("Send")
        .pointerCursor()
    }

    private var annotationPalette: some View {
        HStack(spacing: 4) {
            ForEach(ScreenshotAnnotationTool.allCases) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 4)

            paletteButton(
                iconName: "arrow.uturn.backward",
                helpText: "Undo",
                isDisabled: annotations.isEmpty
            ) {
                _ = annotations.popLast()
            }

            paletteButton(
                iconName: "trash",
                helpText: "Clear annotations",
                isDisabled: annotations.isEmpty
            ) {
                annotations.removeAll()
            }

            Button("Done") {
                isAnnotationPaletteVisible = false
                selectedTool = nil
                isPromptFocused = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .pointerCursor()
        }
        .padding(6)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
    }

    private func toolButton(_ tool: ScreenshotAnnotationTool) -> some View {
        Button {
            selectedTool = selectedTool == tool ? nil : tool
            isPromptFocused = true
        } label: {
            Image(systemName: tool.iconName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTool == tool ? Color.white : Color.primary)
        .background(
            selectedTool == tool ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .help(tool.accessibilityLabel)
        .pointerCursor()
    }

    private func paletteButton(
        iconName: String,
        helpText: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .help(helpText)
        .pointerCursor()
    }

    private var annotationCanvas: some View {
        GeometryReader { geometryProxy in
            Canvas { context, canvasSize in
                for annotation in annotations + [activeAnnotation].compactMap({ $0 }) {
                    draw(annotation: annotation, context: &context, canvasSize: canvasSize)
                }
            }
            .contentShape(Rectangle())
            .gesture(annotationGesture(canvasSize: geometryProxy.size))
        }
        .ignoresSafeArea()
        .allowsHitTesting(selectedTool != nil)
    }

    private func annotationGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { dragValue in
                guard let selectedTool else { return }
                let normalizedLocation = normalize(dragValue.location, canvasSize: canvasSize)
                if selectedTool == .eraser {
                    eraseAnnotation(at: normalizedLocation)
                    return
                }

                if activeAnnotation == nil {
                    activeAnnotation = ScreenshotAnnotation(
                        tool: selectedTool,
                        normalizedPoints: [normalizedLocation]
                    )
                } else if selectedTool == .pen {
                    activeAnnotation?.normalizedPoints.append(normalizedLocation)
                } else if activeAnnotation?.normalizedPoints.count == 1 {
                    activeAnnotation?.normalizedPoints.append(normalizedLocation)
                } else {
                    activeAnnotation?.normalizedPoints[1] = normalizedLocation
                }
            }
            .onEnded { _ in
                if let activeAnnotation,
                   activeAnnotation.normalizedPoints.count > 1 {
                    annotations.append(activeAnnotation)
                }
                activeAnnotation = nil
                isPromptFocused = true
            }
    }

    private func draw(
        annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        guard let firstPoint = annotation.normalizedPoints.first else { return }
        let firstCanvasPoint = denormalize(firstPoint, canvasSize: canvasSize)
        var path = Path()

        switch annotation.tool {
        case .pen:
            path.move(to: firstCanvasPoint)
            for point in annotation.normalizedPoints.dropFirst() {
                path.addLine(to: denormalize(point, canvasSize: canvasSize))
            }
        case .arrow:
            guard let lastPoint = annotation.normalizedPoints.last else { return }
            let lastCanvasPoint = denormalize(lastPoint, canvasSize: canvasSize)
            path.move(to: firstCanvasPoint)
            path.addLine(to: lastCanvasPoint)
            appendArrowhead(to: &path, startPoint: firstCanvasPoint, endPoint: lastCanvasPoint)
        case .rectangle, .ellipse:
            guard let lastPoint = annotation.normalizedPoints.last else { return }
            let annotationRect = canvasRect(
                from: firstPoint,
                to: lastPoint,
                canvasSize: canvasSize
            )
            if annotation.tool == .rectangle {
                path.addRoundedRect(in: annotationRect, cornerSize: CGSize(width: 8, height: 8))
            } else {
                path.addEllipse(in: annotationRect)
            }
        case .eraser:
            return
        }

        context.stroke(
            path,
            with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(.red),
            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        )
    }

    private func appendArrowhead(to path: inout Path, startPoint: CGPoint, endPoint: CGPoint) {
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let arrowheadLength: CGFloat = 18
        let arrowheadAngle: CGFloat = .pi / 6
        path.move(to: CGPoint(
            x: endPoint.x - arrowheadLength * cos(angle - arrowheadAngle),
            y: endPoint.y - arrowheadLength * sin(angle - arrowheadAngle)
        ))
        path.addLine(to: endPoint)
        path.addLine(to: CGPoint(
            x: endPoint.x - arrowheadLength * cos(angle + arrowheadAngle),
            y: endPoint.y - arrowheadLength * sin(angle + arrowheadAngle)
        ))
    }

    private func eraseAnnotation(at normalizedLocation: CGPoint) {
        guard let annotationIndex = annotations.lastIndex(where: { annotation in
            annotationBounds(annotation).insetBy(dx: -0.025, dy: -0.025).contains(normalizedLocation)
        }) else { return }
        annotations.remove(at: annotationIndex)
    }

    private func annotationBounds(_ annotation: ScreenshotAnnotation) -> CGRect {
        let xCoordinates = annotation.normalizedPoints.map(\.x)
        let yCoordinates = annotation.normalizedPoints.map(\.y)
        guard let minimumX = xCoordinates.min(), let maximumX = xCoordinates.max(),
              let minimumY = yCoordinates.min(), let maximumY = yCoordinates.max() else {
            return .zero
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: max(maximumX - minimumX, 0.01),
            height: max(maximumY - minimumY, 0.01)
        )
    }

    private func normalize(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(canvasSize.width, 1), 0), 1),
            y: min(max(point.y / max(canvasSize.height, 1), 0), 1)
        )
    }

    private func denormalize(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
    }

    private func canvasRect(from firstPoint: CGPoint, to lastPoint: CGPoint, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: min(firstPoint.x, lastPoint.x) * canvasSize.width,
            y: min(firstPoint.y, lastPoint.y) * canvasSize.height,
            width: max(abs(lastPoint.x - firstPoint.x) * canvasSize.width, 8),
            height: max(abs(lastPoint.y - firstPoint.y) * canvasSize.height, 8)
        )
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !annotations.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPrompt = trimmedPrompt.isEmpty
            ? "Explain what I marked and guide me through it."
            : trimmedPrompt
        onSubmit(submittedPrompt, annotations)
    }
}
