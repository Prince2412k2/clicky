import Foundation

enum OpenClickyInteractionMode: String, CaseIterable, Identifiable {
    case automatic
    case ask
    case guide
    case act

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum GuidedSessionDirective: String, Equatable {
    case continueGuiding = "continue"
    case done
}

struct GuidedSessionParseResult: Equatable {
    let responseText: String
    let directive: GuidedSessionDirective?
}

enum GuidedSessionParser {
    static func parse(from responseText: String) -> GuidedSessionParseResult {
        let pattern = #"\[GUIDE:(continue|done)\]"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern),
              let match = regularExpression.firstMatch(
                  in: responseText,
                  range: NSRange(responseText.startIndex..., in: responseText)
              ),
              let directiveRange = Range(match.range(at: 1), in: responseText),
              let directive = GuidedSessionDirective(rawValue: String(responseText[directiveRange])) else {
            return GuidedSessionParseResult(responseText: responseText, directive: nil)
        }

        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        let cleanedResponse = regularExpression
            .stringByReplacingMatches(in: responseText, range: responseRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GuidedSessionParseResult(responseText: cleanedResponse, directive: directive)
    }
}
