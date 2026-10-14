import Foundation

public struct TrackerConfig: Sendable {
    public var rules: WriteOffRules
    public var defaultType: WorkType
    public var calendar: Calendar

    public init(rules: WriteOffRules = .init(), defaultType: WorkType = .analysis, calendar: Calendar = .current) {
        self.rules = rules
        self.defaultType = defaultType
        self.calendar = calendar
    }
}

/// Что получилось, когда закончился отрезок.
public enum TrackerEvent: Equatable, Sendable {
    /// Отрезок к списанию: показать карточку или списать сразу.
    case draft(SegmentDraft)
    /// Отрезок короче порога, не списывается.
    case tooShort(issueId: String, rawMinutes: Int)
}

/// Решение в окне «Вы вернулись».
public enum IdleChoice: Equatable, Sendable {
    case otherIssue(String)
    case keepCurrent
    case discard
    /// Завершить рабочий день в начале простоя.
    case endDay
}

/// Всё состояние учёта, которое переживает перезапуск. Сохраняется целиком в JSON.
public struct TrackerState: Codable, Sendable {
    public var phase: DayPhase = .notStarted
    public var current: ActiveSegment?
    public var paused = false
    /// Последняя активная задача: её предлагает «Продолжить работу».
    public var lastIssueId: String?
    public var plan: [String] = []
    /// День, к которому относится `plan`.
    public var planDay: Date?
    /// План последнего рабочего дня.
    public var previousPlan: [String] = []
    public var entries: [LogEntry] = []
    public var deletions: [PendingDeletion] = []
    /// Отрезки, по которым висит карточка списания.
    public var drafts: [SegmentDraft] = []
    public var lastTypeByIssue: [String: WorkType] = [:]
    /// Кэш задач: `idReadable` → задача.
    public var issues: [String: Issue] = [:]
    public var lastCreatedProjectId: String?
    /// Задача, на которую в прошлый раз списывали простой.
    public var lastIdleIssueId: String?
    /// Последний момент, когда пользователь точно был за компьютером.
    public var lastActivity: Date?
    /// С какого момента учёт не идёт (для напоминания о забытом старте).
    public var untrackedSince: Date?
    public var lastAutoMorningDay: Date?
    /// Списания из YouTrack. Optional — чтобы читались файлы состояния, сохранённые до появления поля
    /// (синтезированный Decodable не подставляет значения по умолчанию для отсутствующих ключей).
    private var storedExternal: [ExternalWorkItem]?

    public var external: [ExternalWorkItem] {
        get { storedExternal ?? [] }
        set { storedExternal = newValue }
    }

    public init() {}

    // MARK: - Чтение

    public var status: TrackerStatus {
        if let current { return .tracking(current) }
        switch phase {
        case .notStarted: return .notStarted
        case .ended: return .ended
        case .started: return paused ? .paused : .idle
        }
    }

    /// Какую задачу запустит «Начать работу» / «Продолжить работу».
    public var startCandidate: String? {
        if let lastIssueId, plan.contains(lastIssueId) { return lastIssueId }
        return plan.first
    }

    public func elapsedMinutes(at now: Date) -> Int {
        current.map { TimeMath.minutes(from: $0.start, to: now) } ?? 0
    }

    public func entries(on day: Date, calendar: Calendar) -> [LogEntry] {
        entries
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.end > $1.end }
    }

    /// Списания из YouTrack за день без тех, что сделал сам TickTrack или удалил и ещё не отправил удаление.
    public func externalItems(on day: Date, calendar: Calendar) -> [ExternalWorkItem] {
        let date = TimeMath.youTrackDate(for: day, calendar: calendar)
        let known = Set(entries.compactMap(\.workItemId)).union(deletions.map(\.workItemId))
        return external.filter { $0.date == date && !known.contains($0.id) }
    }

    /// Своё и сделанное напрямую в YouTrack.
    public func loggedMinutes(issueId: String, on day: Date, calendar: Calendar) -> Int {
        entries(on: day, calendar: calendar).filter { $0.issueId == issueId }.reduce(0) { $0 + $1.minutes }
            + externalItems(on: day, calendar: calendar).filter { $0.issueId == issueId }.reduce(0) { $0 + $1.minutes }
    }

    public func totalMinutes(on day: Date, calendar: Calendar) -> Int {
        entries(on: day, calendar: calendar).reduce(0) { $0 + $1.minutes }
            + externalItems(on: day, calendar: calendar).reduce(0) { $0 + $1.minutes }
    }

    public var hasPendingSync: Bool {
        !deletions.isEmpty || entries.contains { $0.sync != .synced }
    }

    // MARK: - План и кэш

    public mutating func remember(_ list: [Issue]) {
        for issue in list { issues[issue.idReadable] = issue }
    }

    public mutating func addToPlan(_ issueId: String) {
        if !plan.contains(issueId) { plan.append(issueId) }
    }

    public mutating func removeFromPlan(_ issueId: String) {
        plan.removeAll { $0 == issueId }
    }

    /// Перетаскивание в «Плане на день»: задача встаёт на место `target`, остальные сдвигаются.
    /// Порядок задаёт цифры 1–9 в меню.
    public mutating func movePlanItem(_ issueId: String, to target: String) {
        guard issueId != target, let from = plan.firstIndex(of: issueId), let to = plan.firstIndex(of: target) else { return }
        plan.remove(at: from)
        plan.insert(issueId, at: to)
    }

    /// Задачи из плана последнего рабочего дня, которых ещё нет в плане.
    public var previousPlanSuggestions: [String] {
        previousPlan.filter { !plan.contains($0) }
    }

    /// Новый календарный день: вчерашний план становится «планом последнего рабочего дня».
    /// Пока идёт отрезок, день не переключаем: он разделится по полуночи при завершении.
    public mutating func rollOver(now: Date, calendar: Calendar) {
        guard current == nil else { return }
        let today = calendar.startOfDay(for: now)
        guard let day = planDay else {
            planDay = today
            return
        }
        guard day < today else { return }
        if !plan.isEmpty { previousPlan = plan }
        plan = []
        planDay = today
        phase = .notStarted
        paused = false
    }

    public mutating func beginDay(plan newPlan: [String], at now: Date, calendar: Calendar) {
        var unique: [String] = []
        for id in newPlan where !unique.contains(id) { unique.append(id) }
        plan = unique
        planDay = calendar.startOfDay(for: now)
        phase = .started
        paused = false
    }

    // MARK: - Учёт

    /// Заканчивает идущий отрезок в момент `end`.
    public mutating func finishCurrent(at end: Date, config: TrackerConfig) -> [TrackerEvent] {
        guard let segment = current else { return [] }
        current = nil
        let end = max(end, segment.start)
        untrackedSince = end
        return events(for: segment.issueId, from: segment.start, to: end, type: nil, config: config)
    }

    /// Заканчивает текущий отрезок и с той же минуты начинает новый по `issueId`.
    public mutating func start(issueId: String, at time: Date, config: TrackerConfig) -> [TrackerEvent] {
        if current?.issueId == issueId { return [] }
        var startAt = time
        var result: [TrackerEvent] = []
        if let segment = current {
            startAt = max(time, segment.start)
            result = finishCurrent(at: startAt, config: config)
        }
        addToPlan(issueId)
        current = ActiveSegment(issueId: issueId, start: startAt)
        paused = false
        lastIssueId = issueId
        if phase != .started {
            phase = .started
            if planDay == nil { planDay = config.calendar.startOfDay(for: startAt) }
        }
        return result
    }

    public mutating func pause(at time: Date, config: TrackerConfig) -> [TrackerEvent] {
        guard current != nil else { return [] }
        let result = finishCurrent(at: time, config: config)
        paused = true
        return result
    }

    public mutating func endDay(at time: Date, config: TrackerConfig) -> [TrackerEvent] {
        let result = finishCurrent(at: time, config: config)
        paused = false
        phase = .ended
        return result
    }

    /// Учёт шёл, а пользователь ушёл и вернулся уже в другой календарный день: день не завершили.
    public func isForgottenDay(lastSeen: Date, now: Date, calendar: Calendar) -> Bool {
        current != nil && lastSeen < now && !calendar.isDate(lastSeen, inSameDayAs: now)
    }

    /// Забытый день завершается в момент `lastSeen`, когда пользователя видели в последний раз, — ночь не списывается.
    /// Новый день начинается как обычно: план уходит во «вчерашний», день не начат.
    public mutating func endForgottenDay(lastSeen: Date, now: Date, config: TrackerConfig) -> [TrackerEvent] {
        guard isForgottenDay(lastSeen: lastSeen, now: now, calendar: config.calendar) else { return [] }
        let result = endDay(at: lastSeen, config: config)
        rollOver(now: now, calendar: config.calendar)
        return result
    }

    /// «Я забыл переключиться»: последние `minutes` минут переносятся на `issueId`.
    /// Минуты отсчитываются от `asOf` — момента, когда открыли окно, а не когда нажали «Перенести»:
    /// время, пока решали, тоже уходит новой задаче, а не остаётся огрызком на старой.
    /// Выбрано всё время отрезка — переносится весь отрезок, по старой задаче не списывается ничего.
    public mutating func reassign(lastMinutes minutes: Int, to issueId: String, asOf: Date, config: TrackerConfig) -> [TrackerEvent] {
        guard let segment = current, segment.issueId != issueId else { return [] }
        let boundary = minutes >= elapsedMinutes(at: asOf)
            ? segment.start
            : max(segment.start, asOf.addingTimeInterval(-Double(max(0, minutes)) * 60))
        return start(issueId: issueId, at: boundary, config: config)
    }

    /// Решение после простоя с `idleStart` до `returnedAt`.
    public mutating func resolveIdle(
        from idleStart: Date, to returnedAt: Date, choice: IdleChoice, continueTracking: Bool, config: TrackerConfig
    ) -> [TrackerEvent] {
        guard let segment = current else { return [] }
        if choice == .endDay {
            return endDay(at: min(idleStart, returnedAt), config: config)
        }
        if choice == .keepCurrent {
            return continueTracking ? [] : pause(at: returnedAt, config: config)
        }
        let idleStart = min(max(idleStart, segment.start), returnedAt)
        var result = finishCurrent(at: idleStart, config: config)
        if case .otherIssue(let other) = choice {
            lastIdleIssueId = other
            result += events(for: other, from: idleStart, to: returnedAt, type: .call, config: config)
        }
        if continueTracking {
            current = ActiveSegment(issueId: segment.issueId, start: returnedAt)
            paused = false
        } else {
            paused = true
            untrackedSince = returnedAt
        }
        return result
    }

    private func events(for issueId: String, from start: Date, to end: Date, type: WorkType?, config: TrackerConfig) -> [TrackerEvent] {
        let parts = TimeMath.splitAtMidnight(start: start, end: end, calendar: config.calendar)
        return parts.compactMap { part in
            let raw = TimeMath.minutes(from: part.start, to: part.end)
            // Меньше полуминуты округляется до 0. Если это весь отрезок — сообщаем «не списано»; обрезок у полуночи
            // и отрезок нулевой длины (перенесли всё время на другую задачу) отбрасываются молча.
            if raw < 1 { return parts.count == 1 && part.end > part.start ? .tooShort(issueId: issueId, rawMinutes: 0) : nil }
            if config.rules.isTooShort(raw: raw) { return .tooShort(issueId: issueId, rawMinutes: raw) }
            return .draft(SegmentDraft(
                issueId: issueId, start: part.start, end: part.end, rawMinutes: raw,
                minutes: raw,
                suggestedType: type ?? lastTypeByIssue[issueId] ?? config.defaultType
            ))
        }
    }

    // MARK: - Списания

    @discardableResult
    public mutating func commit(_ draft: SegmentDraft, comment: String, type: WorkType) -> LogEntry {
        drafts.removeAll { $0.id == draft.id }
        let entry = LogEntry(
            id: draft.id, issueId: draft.issueId, rawMinutes: draft.rawMinutes, minutes: draft.minutes,
            comment: CommentText.finalized(comment, type: type), type: type, start: draft.start, end: draft.end
        )
        entries.append(entry)
        lastTypeByIssue[draft.issueId] = type
        return entry
    }

    public mutating func discardDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    /// Правка из «Списаний за сегодня». Смена задачи = удалить старый work item и создать новый.
    public mutating func updateEntry(id: UUID, issueId: String, minutes: Int, comment: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        if issueId != entry.issueId, let workItemId = entry.workItemId {
            deletions.append(PendingDeletion(issueId: entry.issueId, workItemId: workItemId, minutes: entry.minutes, announce: false))
            entry.workItemId = nil
            entry.sync = .pendingCreate
        } else if entry.workItemId != nil {
            entry.sync = .pendingUpdate
        }
        entry.issueId = issueId
        entry.minutes = max(1, minutes)
        entry.comment = comment
        entry.type = CommentText.type(of: comment) ?? entry.type
        entry.revision += 1
        entry.lastError = nil
        entries[index] = entry
    }

    public mutating func deleteEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        if let workItemId = entry.workItemId {
            deletions.append(PendingDeletion(issueId: entry.issueId, workItemId: workItemId, minutes: entry.minutes, announce: true))
        }
    }

    // MARK: - Ответы сервера

    /// Сервер создал work item для версии `revision` записи на задаче `issueId`.
    public mutating func markCreated(entryId: UUID, workItemId: String, issueId: String, revision: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }), entries[index].issueId == issueId else {
            // Запись удалили или перенесли на другую задачу, пока шёл запрос: созданное надо убрать.
            deletions.append(PendingDeletion(issueId: issueId, workItemId: workItemId, minutes: 0, announce: false))
            return
        }
        entries[index].workItemId = workItemId
        entries[index].lastError = nil
        entries[index].sync = entries[index].revision == revision ? .synced : .pendingUpdate
    }

    public mutating func markUpdated(entryId: UUID, revision: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].lastError = nil
        if entries[index].revision == revision, entries[index].sync == .pendingUpdate {
            entries[index].sync = .synced
        }
    }

    public mutating func setError(entryId: UUID, message: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].lastError = message
    }

    public mutating func removeDeletion(id: UUID) {
        deletions.removeAll { $0.id == id }
    }

    public mutating func setDeletionError(id: UUID, message: String) {
        guard let index = deletions.firstIndex(where: { $0.id == id }) else { return }
        deletions[index].lastError = message
    }

    /// Свежий список моих списаний из YouTrack за день `date` (мс) заменяет прежний за этот день.
    public mutating func replaceExternal(_ items: [ExternalWorkItem], forDate date: Int64) {
        external = external.filter { $0.date != date } + items
    }

    /// Убирает отправленные записи старше `days` дней.
    public mutating func prune(keepingDays days: Int, now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else { return }
        entries.removeAll { $0.sync == .synced && $0.start < cutoff }
        let oldest = TimeMath.youTrackDate(for: cutoff, calendar: calendar)
        external.removeAll { $0.date < oldest }
    }
}
