import Foundation
import TickTrackCore

/// Работа с YouTrack: поиск, создание задач и очередь отправки списаний.
extension AppModel {
    func checkConnection() async {
        guard let api else {
            connection = .failed("Укажите адрес сервера и токен.")
            return
        }
        connection = .checking
        do {
            let user = try await api.currentUser()
            connection = .connected(user.fullName ?? user.login)
            currentUserId = user.id
            // Связь есть: отправляем очередь и подтягиваем задачи «в работе».
            await sync()
            await loadInProgress(force: true)
            await refreshExternal(force: true)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// Обновляет названия и проекты задач из YouTrack: недостающие появляются, переименованные — освежаются.
    /// Без связи молча оставляет то, что есть в кэше.
    func refreshIssues(_ ids: [String]) async {
        guard let api else { return }
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        guard !unique.isEmpty else { return }
        let results = await withTaskGroup(of: (String, Result<Issue, Error>).self) { group in
            for id in unique {
                group.addTask {
                    do { return (id, .success(try await api.issue(id: id))) } catch { return (id, .failure(error)) }
                }
            }
            var all: [(String, Result<Issue, Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        var found: [Issue] = []
        for (id, result) in results {
            switch result {
            case .success(let issue):
                found.append(issue)
                unavailableIssues.remove(id)
            case .failure(let error as YouTrackError) where error == .notFound || error == .forbidden:
                unavailableIssues.insert(id)
            case .failure:
                break
            }
        }
        if !found.isEmpty { mutateState { $0.remember(found) } }
    }

    /// Задачи плана при открытии меню и запуске — не чаще раза в 15 минут.
    func refreshPlanIssuesIfStale() async {
        guard Date().timeIntervalSince(planIssuesRefreshedAt) > 15 * 60 else { return }
        planIssuesRefreshedAt = Date()
        await refreshIssues(state.plan)
    }

    /// Сброс кэшей после смены сервера или токена.
    func connectionSettingsChanged() {
        connection = .unknown
        clearSearchCache()
        unavailableIssues = []
        planIssuesRefreshedAt = .distantPast
    }

    /// Забирает мои списания за сегодня из YouTrack, чтобы учесть сделанные мимо TickTrack.
    /// Без связи молча оставляет то, что было загружено раньше.
    func refreshExternal(force: Bool = false) async {
        guard let api, force || Date().timeIntervalSince(lastExternalRefresh) > 30 else { return }
        lastExternalRefresh = Date()
        let today = Date()
        let date = TimeMath.youTrackDate(for: today, calendar: calendar)
        let day = calendar.dateComponents([.year, .month, .day], from: today)
        let dayString = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        do {
            if currentUserId == nil { currentUserId = try await api.currentUser().id }
            guard let userId = currentUserId else { return }
            let result = try await api.workItems(authorId: userId, day: dayString)
            mutateState {
                $0.remember(result.issues)
                $0.replaceExternal(result.items.filter { $0.date == date }, forDate: date)
            }
        } catch {
            // Не мешаем работе: покажем то, что уже знаем, и попробуем позже.
        }
    }

    func loadInProgress(force: Bool = false) async {
        guard let api, !inProgressLoading else { return }
        guard force || inProgress.isEmpty else { return }
        inProgressLoading = true
        defer { inProgressLoading = false }
        do {
            let list = try await api.searchIssues(query: settings.inProgressQuery, top: 50)
            remember(list)
            inProgress = list
            save()
        } catch {
            // Подсказки «в работе» необязательны: без сети просто не показываем их.
        }
    }

    func loadProjects() async {
        guard let api, projects.isEmpty else { return }
        if let list = try? await api.projects() {
            projects = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Поиск по всем проектам. Свежие результаты берутся из кэша, без сети — поиск по известным задачам.
    func searchIssues(_ text: String) async -> [Issue] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = query.lowercased()
        guard !key.isEmpty else { return [] }
        if let cached = cachedSearch(key) { return cached }
        guard let api else { return localSearch(key) }
        do {
            let found = try await api.searchIssues(query: query, top: 20)
            remember(found)
            storeSearch(key, found)
            return found
        } catch {
            return localSearch(key)
        }
    }

    private func localSearch(_ key: String) -> [Issue] {
        state.issues.values
            .filter { $0.idReadable.lowercased().contains(key) || $0.summary.lowercased().contains(key) || $0.projectName.lowercased().contains(key) }
            .sorted { $0.idReadable < $1.idReadable }
    }

    var defaultProjectId: String? {
        if let id = state.lastCreatedProjectId { return id }
        if let current = state.current, let project = issue(current.issueId)?.project { return project.id }
        return nil
    }

    /// Создаёт задачу в YouTrack, добавляет в план и при необходимости запускает учёт.
    func createIssue(
        summary: String, projectId: String, description: String, assignToMe: Bool, startTracking: Bool, minutesAgo: Int
    ) async throws {
        guard let api else { throw YouTrackError.notConfigured }
        let issue = try await api.createIssue(projectId: projectId, summary: summary, description: description)
        var assigned = false
        if assignToMe {
            do {
                try await api.assignToMe(issueId: issue.idReadable)
                assigned = true
            } catch {
                toast("Не назначено на вас", "\(issue.idReadable): \(error.localizedDescription)", isError: true)
            }
        }
        mutateState { $0.lastCreatedProjectId = projectId }
        addToPlan(issue)
        clearSearchCache()
        toast("Создано в YouTrack", "\(issue.idReadable) · \(Fmt.short(summary, 40))" + (assigned ? " · на вас" : ""))
        if startTracking {
            startIssue(issue.idReadable, at: Date().addingTimeInterval(-Double(max(0, minutesAgo)) * 60))
        }
    }

    // MARK: - Очередь отправки

    func syncSoon() {
        Task { await sync() }
    }

    /// Отправляет всё, что ждёт: удаления, новые и изменённые списания. Без сети записи остаются в очереди.
    func sync() async {
        guard !isSyncingNow, let api else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        markSyncAttempt()

        for deletion in state.deletions {
            do {
                try await api.deleteWorkItem(issueId: deletion.issueId, workItemId: deletion.workItemId)
                finishDeletion(deletion)
            } catch YouTrackError.notFound {
                finishDeletion(deletion)
            } catch {
                recordDeletionError(deletion, error)
                if (error as? YouTrackError)?.isConnectivity == true { return }
            }
        }

        for entry in state.entries where entry.sync != .synced {
            let date = TimeMath.youTrackDate(for: entry.start, calendar: calendar)
            do {
                switch entry.sync {
                case .pendingCreate:
                    let workItemId = try await api.createWorkItem(
                        issueId: entry.issueId, minutes: entry.minutes, text: entry.comment, date: date
                    )
                    mutateState { $0.markCreated(entryId: entry.id, workItemId: workItemId, issueId: entry.issueId, revision: entry.revision) }
                    toast("Списано в YouTrack", "\(entry.issueId) · \(Fmt.hm(entry.minutes)) · «\(Fmt.short(entry.comment, 44))»")
                case .pendingUpdate:
                    guard let workItemId = entry.workItemId else { continue }
                    try await api.updateWorkItem(
                        issueId: entry.issueId, workItemId: workItemId, minutes: entry.minutes, text: entry.comment, date: date
                    )
                    mutateState { $0.markUpdated(entryId: entry.id, revision: entry.revision) }
                    toast("Изменено в YouTrack", "\(entry.issueId) · \(Fmt.hm(entry.minutes))")
                case .synced:
                    continue
                }
            } catch {
                let message = Self.message(for: error, issueId: entry.issueId)
                let isNew = entry.lastError != message
                mutateState { $0.setError(entryId: entry.id, message: message) }
                if isNew {
                    toast("Не отправлено: \(entry.issueId)", message + " Запись ждёт отправки.", isError: true)
                }
                if (error as? YouTrackError)?.isConnectivity == true { return }
            }
        }
    }

    static func message(for error: Error, issueId: String) -> String {
        switch error as? YouTrackError {
        case .notFound?:
            "Задача \(issueId) удалена или недоступна в YouTrack. Выберите другую задачу через «Изменить»."
        case .forbidden?:
            "Нет прав списывать время в \(issueId). Выберите другую задачу через «Изменить»."
        default:
            error.localizedDescription
        }
    }

    private func finishDeletion(_ deletion: PendingDeletion) {
        mutateState { $0.removeDeletion(id: deletion.id) }
        if deletion.announce {
            toast("Удалено из YouTrack", "\(deletion.issueId) · \(Fmt.hm(deletion.minutes))")
        }
    }

    private func recordDeletionError(_ deletion: PendingDeletion, _ error: Error) {
        mutateState { $0.setDeletionError(id: deletion.id, message: error.localizedDescription) }
    }
}
