import Foundation

/// Что не так со связью с YouTrack.
public enum LinkProblem: Equatable, Sendable {
    /// Mac не подключён к сети.
    case noNetwork
    /// Сеть есть, а YouTrack не отвечает.
    case notResponding
    /// YouTrack не принял токен. Само не пройдёт: нужен новый токен в настройках.
    case tokenRejected
}

/// Связь с YouTrack по ответам на запросы.
///
/// Короткие сбои не показываются: после сна или при смене Wi-Fi сеть поднимается секунды, и первая попытка
/// часто неудачна. Проблема появляется, только если запрос не прошёл и через `grace` после первой неудачи.
/// Токен, который YouTrack не принял, — проблема сразу: сама она не пройдёт.
public struct LinkWatch: Equatable, Sendable {
    public static let grace: TimeInterval = 60

    /// Первая неудача текущего сбоя; `nil` — последний запрос прошёл.
    public private(set) var failingSince: Date?
    /// Проблема, о которой знает пользователь.
    public private(set) var problem: LinkProblem?

    public init() {}

    /// Сбой идёт, даже если о нём ещё не сказали.
    public var isFailing: Bool { failingSince != nil || problem != nil }

    /// Учитывает ответ на запрос (`error == nil` — запрос прошёл).
    /// Возвращает `true`, если была проблема, а теперь связь есть.
    @discardableResult
    public mutating func record(_ error: Error?, networkAvailable: Bool, at time: Date) -> Bool {
        guard let error else { return recover() }
        guard let error = error as? YouTrackError else { return false }
        switch error {
        case .unauthorized:
            if failingSince == nil { failingSince = time }
            problem = .tokenRejected
            return false
        case .notConfigured:
            return false
        case _ where error.isConnectivity:
            let since = failingSince ?? time
            failingSince = since
            if time.timeIntervalSince(since) >= Self.grace {
                problem = networkAvailable ? .notResponding : .noNetwork
            }
            return false
        default:
            // YouTrack ответил (задачи нет, нет прав, ошибка в данных): связь есть.
            return recover()
        }
    }

    /// Неудача до сна и неудача сразу после пробуждения — не минута без связи: отсчёт начинается заново.
    /// Уже показанная проблема остаётся до первого удачного запроса.
    public mutating func restartGrace() {
        if problem == nil { failingSince = nil }
    }

    private mutating func recover() -> Bool {
        let hadProblem = problem != nil
        failingSince = nil
        problem = nil
        return hadProblem
    }
}
