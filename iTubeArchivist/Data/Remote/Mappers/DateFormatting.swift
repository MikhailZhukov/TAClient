import Foundation

enum DateFormatting {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func formatISO(_ isoString: String?, style: DateFormatter.Style = .medium) -> String {
        guard let isoString else { return "" }
        let date: Date?
        if let d = isoFormatter.date(from: isoString) {
            date = d
        } else if let d = isoFormatterBasic.date(from: isoString) {
            date = d
        } else {
            // Try simple date-only format
            let simple = DateFormatter()
            simple.dateFormat = "yyyy-MM-dd"
            date = simple.date(from: String(isoString.prefix(10)))
        }

        guard let date else { return isoString }

        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .none

        // Use non-breaking spaces to prevent wrapping
        return formatter.string(from: date).replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func formatUnixTimestamp(_ timestamp: Int?, style: DateFormatter.Style = .medium) -> String {
        guard let timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))

        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .none

        return formatter.string(from: date).replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}
