import Foundation
import Network
import TickTrackCore

/// Что ждёт отправки в YouTrack: число списаний, их время и глаголы, согласованные с числом.
struct PendingSummary {
    let count: Int
    let minutes: Int

    /// «3 списания».
    var phrase: String { RussianPlural.count(count, "списание", "списания", "списаний") }

    /// «уйдёт» для одного списания, «уйдут» для нескольких.
    func verb(_ one: String, _ many: String) -> String { RussianPlural.isSingular(count) ? one : many }
}

/// Связь с YouTrack: что сказать пользователю, когда её нет, и как вернуть очередь, когда она появится.
extension AppModel {
    /// Списания, которые ещё не дошли до YouTrack. Удаления не считаем: в них нет времени, которое можно потерять.
    var pendingSummary: PendingSummary? {
        let pending = state.pendingEntries
        guard !pending.isEmpty else { return nil }
        return PendingSummary(count: pending.count, minutes: pending.reduce(0) { $0 + $1.minutes })
    }

    /// Карточка в углу — только когда в очереди есть что терять; без очереди хватает точки и строки в меню.
    var showsLinkCard: Bool {
        link.problem != nil && state.hasPendingSync && !linkCardHidden
    }

    /// Учитывает ответ на запрос к YouTrack. Вызывается обёрткой `ReportingYouTrack` после каждого запроса.
    func noteLink(_ error: Error?) {
        var updated = link
        let previous = link.problem
        let recovered = updated.record(error, networkAvailable: networkAvailable, at: Date())
        // Присваиваем, только если что-то поменялось: иначе каждый запрос перерисовывал бы меню и значок.
        if updated != link { link = updated }
        if previous == nil, link.problem != nil { linkCardHidden = false }
        if recovered, let previous { linkRecovered(from: previous) }
    }

    /// Связь вернулась. Если в очереди что-то есть, о восстановлении скажет отправка — одним сообщением со всем отправленным.
    private func linkRecovered(from problem: LinkProblem) {
        recoveredFrom = problem
        linkCardHidden = false
        guard !isSyncingNow else { return }
        if state.hasPendingSync { syncSoon() } else { announceRecovery(sent: []) }
    }

    func announceRecovery(sent: [LogEntry]) {
        let problem = recoveredFrom
        recoveredFrom = nil
        let title = problem == .tokenRejected ? "YouTrack принял токен" : "Связь с YouTrack восстановлена"
        guard !sent.isEmpty else {
            toast(title, "Списания снова уходят в YouTrack сразу.")
            return
        }
        let summary = PendingSummary(count: sent.count, minutes: sent.reduce(0) { $0 + $1.minutes })
        toast(title, "\(summary.verb("Отправлено", "Отправлены")) \(summary.phrase) · \(Fmt.hm(summary.minutes))")
    }

    /// После неудачной попытки связи нет: о записях, которые не ушли впервые, говорим один раз — они сохранены и уйдут сами.
    /// Повторные попытки идут молча: о том, что связи по-прежнему нет, говорят точка, меню и карточка.
    func noteWaiting(_ error: Error) {
        let tokenRejected = (error as? YouTrackError) == .unauthorized
        let message = tokenRejected
            ? "YouTrack не принял токен. Уйдёт, когда вы укажете новый токен в настройках."
            : "Нет связи с YouTrack. Уйдёт, когда связь появится."
        var marked: [LogEntry] = []
        mutateState { marked = $0.markWaiting(message: message) }
        guard !marked.isEmpty else { return }
        let summary = PendingSummary(count: marked.count, minutes: marked.reduce(0) { $0 + $1.minutes })
        let what = marked.count == 1 ? marked[0].issueId : summary.phrase
        let when = tokenRejected ? "когда вы укажете новый токен" : "когда появится связь"
        toast(
            "Сохранено, отправим позже",
            "\(what) · \(Fmt.hm(summary.minutes)) · \(summary.verb("уйдёт", "уйдут")) в YouTrack, \(when)"
        )
    }

    /// Ошибка, после которой остальную очередь отправлять бесполезно: связи нет или токен не принят.
    static func stopsQueue(_ error: Error) -> Bool {
        guard let error = error as? YouTrackError else { return false }
        return error.isConnectivity || error == .unauthorized
    }

    func hideLinkCard() {
        linkCardHidden = true
    }

    /// «Повторить сейчас»: отправить очередь, а если она пуста — просто проверить связь.
    func retryLink() {
        guard !linkRetrying else { return }
        linkRetrying = true
        Task {
            if state.hasPendingSync { await sync() } else { await checkConnection() }
            linkRetrying = false
        }
    }

    /// Пока связи нет, а отправлять нечего, раз в 30 секунд проверяем её сами: иначе точка не погаснет до следующего запроса.
    /// С очередью проверка не нужна — очередь и так отправляется каждые 30 секунд.
    func probeLinkIfNeeded() {
        guard link.isFailing, !state.hasPendingSync, now.timeIntervalSince(lastLinkProbe) > 30 else { return }
        lastLinkProbe = now
        Task { await checkConnection() }
    }

    /// Mac проснулся: неудача до сна не в счёт минуты без связи, и сеть стоит проверить сразу.
    func linkAfterWake() {
        var updated = link
        updated.restartGrace()
        if updated != link { link = updated }
        lastLinkProbe = .distantPast
    }

    /// Следит за сетью: появилась — отправляем очередь сразу, не дожидаясь очередной попытки.
    func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: available) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func networkChanged(available: Bool) {
        let appeared = available && !networkAvailable
        networkAvailable = available
        guard appeared else { return }
        if state.hasPendingSync {
            syncSoon()
        } else if link.isFailing {
            lastLinkProbe = Date()
            Task { await checkConnection() }
        }
    }
}

/// Передаёт модели исход каждого запроса к YouTrack: по ним видно, есть ли связь.
nonisolated struct ReportingYouTrack: YouTrackAPI {
    let base: any YouTrackAPI
    let report: @Sendable (Error?) async -> Void

    private func run<T>(_ request: () async throws -> T) async throws -> T {
        do {
            let result = try await request()
            await report(nil)
            return result
        } catch {
            await report(error)
            throw error
        }
    }

    func currentUser() async throws -> YouTrackUser { try await run { try await base.currentUser() } }

    func searchIssues(query: String, top: Int) async throws -> [Issue] {
        try await run { try await base.searchIssues(query: query, top: top) }
    }

    func issue(id: String) async throws -> Issue { try await run { try await base.issue(id: id) } }

    func projects() async throws -> [Project] { try await run { try await base.projects() } }

    func createIssue(projectId: String, summary: String, description: String) async throws -> Issue {
        try await run { try await base.createIssue(projectId: projectId, summary: summary, description: description) }
    }

    func assignToMe(issueId: String) async throws { try await run { try await base.assignToMe(issueId: issueId) } }

    func createWorkItem(issueId: String, minutes: Int, text: String, date: Int64) async throws -> String {
        try await run { try await base.createWorkItem(issueId: issueId, minutes: minutes, text: text, date: date) }
    }

    func updateWorkItem(issueId: String, workItemId: String, minutes: Int, text: String, date: Int64) async throws {
        try await run { try await base.updateWorkItem(issueId: issueId, workItemId: workItemId, minutes: minutes, text: text, date: date) }
    }

    func deleteWorkItem(issueId: String, workItemId: String) async throws {
        try await run { try await base.deleteWorkItem(issueId: issueId, workItemId: workItemId) }
    }

    func workItems(authorId: String, day: String) async throws -> (items: [ExternalWorkItem], issues: [Issue]) {
        try await run { try await base.workItems(authorId: authorId, day: day) }
    }
}
