import Foundation

public struct DetectedDate {
    public let range: NSRange   // relative to the line it was found in
    public let text: String
    public let due: Date

    public init(range: NSRange, text: String, due: Date) {
        self.range = range
        self.text = text
        self.due = due
    }
}

public enum ReminderState { case upcoming, due }

// Absolute dates, times and date-times in a line of text. Relative ones ("tomorrow", "in 2 hours") are not detected.
public enum DateText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let relativeRegex = try! NSRegularExpression(
        pattern: "\\b(?:in|ago|next|last|this|today|tomorrow|yesterday|tonight|from now)\\b", options: .caseInsensitive)
    private static let timeRegex = try! NSRegularExpression(
        pattern: "\\d:\\d|\\d\\s*[ap]\\.?m|noon|midnight", options: .caseInsensitive)
    // A time of day as written: "17:30", "5:30 pm", "5pm"
    private static let timeTextRegex = try! NSRegularExpression(
        pattern: "\\d{1,2}(?::\\d{2}){1,2}\\s*(?:[ap]\\.?m\\b\\.?)?|\\d{1,2}\\s*[ap]\\.?m\\b\\.?", options: .caseInsensitive)
    private static let numberRegex = try! NSRegularExpression(pattern: "\\d+")

    // Dates found in ONE line. A time alone ("5pm") is taken as today, and is resolved again whenever
    // the line is detected again, so it rolls over to the next day.
    public static func detect(in line: String) -> [DetectedDate] {
        let ns = line as NSString
        var found: [DetectedDate] = []
        detector?.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, let date = m.date else { return }
            let text = ns.substring(with: m.range)
            guard text.contains(where: \.isNumber), !text.allSatisfy(\.isNumber), !isRelative(text),
                  isValid(text, resolvedTo: date) else { return }
            // Without a time of day, the deadline is reached at the start of that day (the detector says noon)
            let due = hasTime(text) ? date : Calendar.current.startOfDay(for: date)
            found.append(DetectedDate(range: m.range, text: text, due: due))
        }
        return found
    }

    public static func state(of d: DetectedDate, now: Date = Date()) -> ReminderState {
        d.due <= now ? .due : .upcoming
    }

    // Whether the text names a time of day
    public static func hasTime(_ text: String) -> Bool {
        timeRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func isRelative(_ text: String) -> Bool {
        relativeRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    // The detector rolls an impossible date over to a real one ("31-02-2026" is 3 March): the day it
    // gives then isn't written in the text. A time alone has no day to check.
    private static func isValid(_ text: String, resolvedTo date: Date) -> Bool {
        let ns = text as NSString
        let dateOnly = timeTextRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                              withTemplate: " ") as NSString
        let numbers = numberRegex.matches(in: dateOnly as String, range: NSRange(location: 0, length: dateOnly.length))
            .compactMap { Int(dateOnly.substring(with: $0.range)) }
        return numbers.isEmpty || numbers.contains(Calendar.current.component(.day, from: date))
    }
}
