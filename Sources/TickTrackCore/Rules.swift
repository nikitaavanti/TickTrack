import Foundation

/// Правила превращения отрезка в списание.
public struct WriteOffRules: Equatable, Sendable {
    /// Отрезки короче этого порога не списываются.
    public var minimumMinutes: Int

    public init(minimumMinutes: Int = 2) {
        self.minimumMinutes = minimumMinutes
    }

    public func isTooShort(raw: Int) -> Bool {
        raw < minimumMinutes
    }
}

public enum TimeMath {
    /// Длительность в целых минутах, с округлением до ближайшей.
    public static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    /// Делит интервал по границам суток: каждый кусок списывается своей датой.
    public static func splitAtMidnight(start: Date, end: Date, calendar: Calendar) -> [(start: Date, end: Date)] {
        guard end > start else { return [(start, end)] }
        var parts: [(start: Date, end: Date)] = []
        var cursor = start
        while let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)),
              midnight < end {
            parts.append((cursor, midnight))
            cursor = midnight
        }
        parts.append((cursor, end))
        return parts
    }

    /// Поле `date` work item: полночь UTC календарного дня отрезка, в миллисекундах.
    public static func youTrackDate(for date: Date, calendar: Calendar) -> Int64 {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: day) ?? date
        return Int64(midnight.timeIntervalSince1970 * 1000)
    }

    /// `ч:мм`.
    public static func hm(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return "\(m / 60):" + (m % 60 < 10 ? "0" : "") + "\(m % 60)"
    }
}

/// Дневная норма списаний.
public struct DailyNorm: Equatable, Sendable {
    /// Норма в минутах, шаг — полчаса.
    public var minutes: Int

    public init(minutes: Int) {
        self.minutes = max(30, minutes)
    }

    /// Сколько процентов нормы списано. Округляется вниз: 100 % — только когда норма набрана.
    public func percent(logged: Int) -> Int {
        max(0, logged) * 100 / minutes
    }

    /// Сколько осталось до нормы, 0 — если набрана.
    public func remaining(logged: Int) -> Int {
        max(0, minutes - logged)
    }

    /// Норма в часах: «8», «7,5».
    public var hoursText: String {
        "\(minutes / 60)" + (minutes % 60 == 0 ? "" : ",\(minutes % 60 * 10 / 60)")
    }
}

/// Комментарий списания с типом работы в виде приставки.
public enum CommentText {
    public static func initial(for type: WorkType) -> String {
        type == .unspecified ? "" : type.rawValue + ": "
    }

    /// Тип работы, записанный в начале комментария.
    public static func type(of text: String) -> WorkType? {
        WorkType.allCases.first { $0 != .unspecified && text.hasPrefix($0.rawValue + ":") }
    }

    /// Меняет только приставку, остальной текст сохраняется.
    public static func replacingType(in text: String, with type: WorkType) -> String {
        initial(for: type) + body(of: text)
    }

    /// Текст без приставки типа.
    public static func body(of text: String) -> String {
        guard let current = self.type(of: text) else { return text }
        let rest = text.dropFirst(current.rawValue.count + 1)
        return String(rest.drop(while: { $0 == " " }))
    }

    /// Итоговый комментарий: без пробелов по краям и без двоеточия в конце. Пустой — просто тип, а без типа — пустой.
    public static func finalized(_ text: String, type: WorkType) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(":") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty && type != .unspecified ? type.rawValue : result
    }
}
