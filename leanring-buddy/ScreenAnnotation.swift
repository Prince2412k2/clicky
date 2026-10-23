import CoreGraphics
import SwiftUI

enum ScreenAnnotationKind: String, Equatable {
    case arrow
    case box
    case highlight
    case pointer
}

struct ScreenAnnotation: Identifiable, Equatable {
    let id = UUID()
    let kind: ScreenAnnotationKind
    let startLocation: CGPoint
    let endLocation: CGPoint
    let label: String?
    let displayFrame: CGRect
}

struct ParsedScreenAnnotation: Equatable {
    let kind: ScreenAnnotationKind
    let coordinates: [CGFloat]
    let label: String?
}

struct ScreenAnnotationParseResult: Equatable {
    let responseText: String
    let annotations: [ParsedScreenAnnotation]
}

enum ScreenAnnotationParser {
    static func parse(from responseText: String) -> ScreenAnnotationParseResult {
        let pattern = #"\[DRAW:([^\]]+)\]"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return ScreenAnnotationParseResult(responseText: responseText, annotations: [])
        }

        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regularExpression.matches(in: responseText, range: responseRange)
        var annotations: [ParsedScreenAnnotation] = []

        for match in matches {
            guard let bodyRange = Range(match.range(at: 1), in: responseText) else { continue }
            let components = responseText[bodyRange].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count >= 2,
                  let kind = ScreenAnnotationKind(rawValue: String(components[0]).lowercased()) else {
                continue
            }

            let coordinates = components[1]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { CGFloat($0) }
            let requiredCoordinateCount = kind == .pointer ? 2 : 4
            guard coordinates.count == requiredCoordinateCount else { continue }

            let label = components.count == 3
                ? String(components[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            annotations.append(
                ParsedScreenAnnotation(
                    kind: kind,
                    coordinates: coordinates,
                    label: label?.isEmpty == true ? nil : label
                )
            )
        }

        let cleanedResponse = regularExpression
            .stringByReplacingMatches(in: responseText, range: responseRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScreenAnnotationParseResult(
            responseText: cleanedResponse,
            annotations: Array(annotations.prefix(6))
        )
    }
}

struct TeachingAnnotationOverlay: View {
    let annotation: ScreenAnnotation
    let screenFrame: CGRect

    @State private var drawingProgress: CGFloat = 0
    @State private var pulseScale: CGFloat = 0.75

    private let annotationColor = Color(red: 0.18, green: 0.58, blue: 1.0)

    var body: some View {
        ZStack {
            switch annotation.kind {
            case .arrow:
                ArrowAnnotationShape(start: localStartLocation, end: localEndLocation)
                    .trim(from: 0, to: drawingProgress)
                    .stroke(
                        annotationColor,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: annotationColor.opacity(0.65), radius: 7)
            case .box:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .trim(from: 0, to: drawingProgress)
                    .stroke(
                        annotationColor,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: annotationRect.width, height: annotationRect.height)
                    .position(x: annotationRect.midX, y: annotationRect.midY)
                    .shadow(color: annotationColor.opacity(0.55), radius: 7)
            case .highlight:
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(annotationColor.opacity(0.18 * drawingProgress))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(annotationColor.opacity(drawingProgress), lineWidth: 3)
                    )
                    .frame(width: annotationRect.width, height: annotationRect.height)
                    .position(x: annotationRect.midX, y: annotationRect.midY)
            case .pointer:
                ZStack {
                    Circle()
                        .stroke(annotationColor.opacity(0.45), lineWidth: 4)
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulseScale)
                    Circle()
                        .fill(annotationColor)
                        .frame(width: 12, height: 12)
                        .shadow(color: annotationColor, radius: 8)
                }
                .position(localStartLocation)
            }

            if let label = annotation.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(annotationColor, in: Capsule())
                    .shadow(color: annotationColor.opacity(0.5), radius: 6)
                    .position(labelLocation)
                    .opacity(drawingProgress)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.65)) {
                drawingProgress = 1
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.2
            }
        }
    }

    private var localStartLocation: CGPoint {
        convertGlobalAppKitPointToLocalSwiftUI(annotation.startLocation)
    }

    private var localEndLocation: CGPoint {
        convertGlobalAppKitPointToLocalSwiftUI(annotation.endLocation)
    }

    private var annotationRect: CGRect {
        let startLocation = localStartLocation
        let endLocation = localEndLocation
        return CGRect(
            x: min(startLocation.x, endLocation.x),
            y: min(startLocation.y, endLocation.y),
            width: max(abs(endLocation.x - startLocation.x), 24),
            height: max(abs(endLocation.y - startLocation.y), 24)
        )
    }

    private var labelLocation: CGPoint {
        let preferredX = annotation.kind == .arrow ? localEndLocation.x : annotationRect.midX
        let preferredY = annotation.kind == .arrow ? localEndLocation.y - 24 : annotationRect.minY - 18
        return CGPoint(
            x: min(max(preferredX, 70), screenFrame.width - 70),
            y: min(max(preferredY, 18), screenFrame.height - 18)
        )
    }

    private func convertGlobalAppKitPointToLocalSwiftUI(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - screenFrame.minX,
            y: screenFrame.maxY - point.y
        )
    }
}

private struct ArrowAnnotationShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowheadLength: CGFloat = 18
        let arrowheadAngle: CGFloat = .pi / 6
        let firstArrowheadPoint = CGPoint(
            x: end.x - arrowheadLength * cos(angle - arrowheadAngle),
            y: end.y - arrowheadLength * sin(angle - arrowheadAngle)
        )
        let secondArrowheadPoint = CGPoint(
            x: end.x - arrowheadLength * cos(angle + arrowheadAngle),
            y: end.y - arrowheadLength * sin(angle + arrowheadAngle)
        )
        path.move(to: firstArrowheadPoint)
        path.addLine(to: end)
        path.addLine(to: secondArrowheadPoint)
        return path
    }
}
