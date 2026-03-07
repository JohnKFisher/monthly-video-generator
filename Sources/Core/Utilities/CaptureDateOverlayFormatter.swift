import Foundation

public enum CaptureDateOverlayFormatter {
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
