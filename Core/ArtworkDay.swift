import Foundation

/// The time of day at which a new artwork begins.
struct ChangeTime: Codable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    static let midnight = ChangeTime(hour: 0, minute: 0)

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

/// Maps wall-clock time to an "artwork day". With a change time of 07:00, 06:59 on
/// Tuesday still belongs to Monday's artwork.
enum ArtworkDay {
    /// The moment a given calendar day's artwork begins. Uses `.nextTime` so that a change
    /// time inside a DST gap (e.g. 02:30 on spring-forward day) still resolves.
    static func changeInstant(onDayContaining date: Date, changeTime: ChangeTime, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: changeTime.hour, minute: changeTime.minute, second: 0, of: start,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? start.addingTimeInterval(TimeInterval(changeTime.hour * 3600 + changeTime.minute * 60))
    }

    /// Stable identifier such as "2026-10-25".
    static func key(for date: Date, changeTime: ChangeTime, calendar: Calendar = .current) -> String {
        var day = date
        if date < changeInstant(onDayContaining: date, changeTime: changeTime, calendar: calendar) {
            day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) ?? date
        }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next moment strictly after `date` at which the artwork day changes.
    static func nextChange(after date: Date, changeTime: ChangeTime, calendar: Calendar = .current) -> Date {
        let today = changeInstant(onDayContaining: date, changeTime: changeTime, calendar: calendar)
        if today > date { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            ?? date.addingTimeInterval(86_400)
        return changeInstant(onDayContaining: tomorrow, changeTime: changeTime, calendar: calendar)
    }
}
