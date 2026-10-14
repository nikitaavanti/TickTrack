import AppKit
import Observation
import ServiceManagement
import TickTrackCore

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var text: String
    var isError = false
}

/// Окно «Вы вернулись»: простой с `start` до `end` при идущем учёте.
struct IdlePrompt: Equatable {
    var start: Date
    var end: Date
    var issueId: String
}

/// Карточка «забытый старт».
struct Reminder: Equatable {
    enum Kind { case dayNotStarted, paused, untracked }
    var kind: Kind
    var minutes: Int
    var since: Date
    var issueId: String?
}

/// Строка «Списаний за сегодня».
enum LogRow: Identifiable {
    case local(LogEntry)
    case external(ExternalWorkItem)

    var id: String {
        switch self {
        case .local(let entry): entry.id.uuidString
        case .external(let item): "yt-" + item.id
        }
    }

    /// У списаний из YouTrack нет времени окончания — сортируем их по времени создания.
    var sortDate: Date {
        switch self {
        case .local(let entry): entry.end
        case .external(let item): item.created ?? .distantPast
        }
    }
}

enum ConnectionStatus: Equatable {
    case unknown
    case checking
    case connected(String)
    case failed(String)
}

enum Indicator {
    case running, paused, idle
}

/// Состояние и действия приложения. Логика учёта — в `TrackerState`, здесь — время, система, YouTrack и окна.
@Observable
final class AppModel {
    let settings: AppSettings
    private(set) var state: TrackerState
    var now = Date()
    var toasts: [Toast] = []
    var reminder: Reminder?
    var idlePrompt: IdlePrompt?
    var connection: ConnectionStatus = .unknown
    var inProgress: [Issue] = []
    var inProgressLoading = false
    /// Задачи, которых нет в YouTrack или к которым нет доступа (по последней проверке).
    var unavailableIssues: Set<String> = []
    var projects: [Project] = []
    /// Растёт при каждом открытии меню, чтобы меню открывалось в исходном виде.
    var menuSession = 0

    @ObservationIgnored let windows = WindowCoordinator()
    @ObservationIgnored weak var menuBar: MenuBarController?
    @ObservationIgnored let calendar = Calendar.current
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var searchCache: [String: (date: Date, issues: [Issue])] = [:]
    @ObservationIgnored var isSyncingNow = false
    @ObservationIgnored private var lastSyncAttempt = Date.distantPast
    @ObservationIgnored private var lastActivitySave = Date.distantPast
    @ObservationIgnored private var inProgressLoadedAt = Date.distantPast
    @ObservationIgnored var planIssuesRefreshedAt = Date.distantPast
    /// С какого момента пользователь не за компьютером (nil — за компьютером).
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var reminderSnoozedUntil = Date.distantPast
    @ObservationIgnored private var demoAPI: (any YouTrackAPI)?
    /// Выход подтверждён: следующий `terminate` закрывает приложение без вопросов.
    @ObservationIgnored var quitConfirmed = false
    @ObservationIgnored var systemIsPoweringOff = false
    /// Что введено в висящих карточках списания.
    @ObservationIgnored var draftInputs: [UUID: DraftInput] = [:]
    /// Карточка по задаче, на которой завершили день: «Итог дня» откроется, когда по ней решат.
    @ObservationIgnored private var dayEndDraft: (id: UUID, quitting: Bool)?
    /// Id текущего пользователя YouTrack: по нему забираем свои списания, сделанные напрямую в YouTrack.
    @ObservationIgnored var currentUserId: String?
    @ObservationIgnored var lastExternalRefresh = Date.distantPast

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        var store = StateStore()
        #if DEBUG
        if ProcessInfo.processInfo.environment["TICKTRACK_DEMO"] == "1" {
            demoAPI = DemoYouTrack()
            // Демо-данные не смешиваются с настоящим учётом.
            store = StateStore(url: StateStore.defaultURL.deletingLastPathComponent().appending(path: "demo-state.json"))
        }
        #endif
        self.store = store
        self.state = store.load()
    }

    var config: TrackerConfig {
        TrackerConfig(rules: settings.rules, defaultType: settings.defaultType, calendar: calendar)
    }

    var api: (any YouTrackAPI)? {
        demoAPI ?? YouTrackClient(server: settings.serverURL, token: settings.token)
    }

    // MARK: - Запуск

    func launch() {
        let now = Date()
        self.now = now
        state.rollOver(now: now, calendar: calendar)
        if state.current == nil {
            state.untrackedSince = now
        } else if let last = state.lastActivity, let current = state.current {
            // Перезапуск или сбой посреди отрезка: день могли не завершить, а пользователя могло давно не быть.
            let dayEnded = endForgottenDay(lastSeen: last, now: now)
            if !dayEnded, settings.autopauseEnabled, now.timeIntervalSince(last) >= idleThreshold {
                presentIdle(IdlePrompt(start: max(last, current.start), end: now, issueId: current.issueId))
            }
        }
        state.prune(keepingDays: 14, now: now, calendar: calendar)
        save()

        HotKeyCenter.shared.onPress = { [weak self] in self?.menuBar?.toggle() }
        applyHotKey()
        applyLaunchAtLogin()
        observeSystem()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Плана на сегодня нет — сначала собрать его. При первом запуске — сразу после настроек,
        // иначе только в рабочий день после его начала: вне расписания TickTrack сам ничего не открывает.
        let needsPlan = state.plan.isEmpty && state.current == nil
        if api == nil {
            openSettings(then: needsPlan ? { [weak self] in
                if let self, api != nil { openPlan() }
            } : nil)
        } else {
            Task { await checkConnection() }
            Task { await refreshPlanIssuesIfStale() }
            if needsPlan, settings.schedule.hasBegun(at: now, calendar: calendar) { openPlan() }
        }
    }

    func save() {
        try? store.save(state)
    }

    // MARK: - Строка меню

    /// Текст рядом с котом — только текущая задача. Без учёта текста нет, состояние видно по коту и точке.
    var menuBarTitle: String? {
        guard let current = state.current else { return nil }
        if settings.menuBarMode == .idAndTitle, let summary = issue(current.issueId)?.summary, !summary.isEmpty {
            return current.issueId + " " + Fmt.short(summary, 16)
        }
        return current.issueId
    }

    var statusToolTip: String {
        if let current = state.current {
            return current.issueId + " — " + (issue(current.issueId)?.summary ?? "")
        }
        return "TickTrack · открыть меню: " + settings.hotKey.display
    }

    var indicator: Indicator {
        switch state.status {
        case .tracking: .running
        case .paused: .paused
        default: .idle
        }
    }

    // MARK: - Справочные данные

    func issue(_ id: String) -> Issue? { state.issues[id] }

    func title(of id: String) -> String { issue(id)?.summary ?? "" }

    var elapsedMinutes: Int { state.elapsedMinutes(at: now) }


    var todayEntries: [LogEntry] { state.entries(on: now, calendar: calendar) }

    /// «Списания за сегодня»: свои и сделанные напрямую в YouTrack, новые сверху.
    var todayRows: [LogRow] {
        let local = todayEntries.map(LogRow.local)
        let external = state.externalItems(on: now, calendar: calendar).map(LogRow.external)
        return (local + external).sorted { $0.sortDate > $1.sortDate }
    }

    var totalToday: Int { state.totalMinutes(on: now, calendar: calendar) }

    /// Процент нормы и остаток — по списанному, без идущего отрезка.
    var normPercentToday: Int { settings.dailyNorm.percent(logged: totalToday) }
    var normRemainingToday: Int { settings.dailyNorm.remaining(logged: totalToday) }

    /// Сколько по задаче сегодня: списано плюс идущий отрезок.
    func spentToday(_ id: String) -> Int {
        state.loggedMinutes(issueId: id, on: now, calendar: calendar) + (state.current?.issueId == id ? elapsedMinutes : 0)
    }

    /// Задачи для выпадающих списков: сначала план, потом остальные известные.
    func pickableIssues(excluding excluded: String? = nil, including included: String? = nil) -> [Issue] {
        var ids = state.plan
        for id in state.issues.keys.sorted() where !ids.contains(id) { ids.append(id) }
        if let included, !ids.contains(included) { ids.insert(included, at: 0) }
        return ids.filter { $0 != excluded }.map { issue($0) ?? Issue(idReadable: $0, summary: "") }
    }

    func isInProgress(_ id: String) -> Bool { inProgress.contains { $0.idReadable == id } }

    // MARK: - Учёт

    private func apply(_ change: (inout TrackerState, TrackerConfig) -> [TrackerEvent]) {
        let events = change(&state, config)
        handle(events)
        save()
    }

    private func handle(_ events: [TrackerEvent]) {
        var committed = false
        for event in events {
            switch event {
            case .draft(let draft):
                if settings.cardEnabled {
                    state.drafts.append(draft)
                } else {
                    state.commit(draft, comment: CommentText.initial(for: draft.suggestedType), type: draft.suggestedType)
                    committed = true
                }
            case .tooShort(let id, let raw):
                toast("Не списано", "\(id) · \(raw) мин, это короче \(settings.minimumMinutes) мин")
            }
        }
        if committed { syncSoon() }
    }

    /// «Начать рабочий день». План уже собран (при запуске или раньше сегодня) — сразу выбор первой задачи.
    /// Плана нет — сначала «План на день», после него день начинается и открывается выбор задачи.
    /// Автопоказ по времени день сам не начинает: это делает пользователь.
    func startDay(automatically: Bool = false) {
        guard !state.plan.isEmpty else {
            reminder = nil
            openPlan(then: { [weak self] in
                // Окно закрыли, ничего не добавив, — день не начинаем.
                guard let self, !state.plan.isEmpty else { return }
                beginDay(plan: state.plan)
                openStartWork()
            })
            return
        }
        closeMenu()
        reminder = nil
        if !automatically { beginDay(plan: state.plan) }
        openStartWork()
    }

    func beginDay(plan: [String]) {
        state.beginDay(plan: plan, at: Date(), calendar: calendar)
        reminder = nil
        save()
    }

    func startIssue(_ id: String, at time: Date? = nil) {
        apply { state, config in state.start(issueId: id, at: time ?? Date(), config: config) }
        reminder = nil
    }

    /// «Начать работу» / «Продолжить работу».
    func resume() {
        guard let id = state.startCandidate else { return }
        startIssue(id)
    }

    func pause() {
        apply { state, config in state.pause(at: Date(), config: config) }
    }

    /// Сначала карточка по активной задаче, потом «Итог дня» — чтобы в итоге было и последнее списание.
    /// Если карточки нет (отрезок короткий, карточки выключены, учёт не шёл), итог открывается сразу.
    func endDay(at time: Date = Date(), quitting: Bool = false) {
        let before = Set(state.drafts.map(\.id))
        apply { state, config in state.endDay(at: time, config: config) }
        reminder = nil
        closeMenu()
        if let draft = state.drafts.last, !before.contains(draft.id) {
            dayEndDraft = (draft.id, quitting)
        } else {
            openDaySummary(quitting: quitting)
        }
    }

    private func openDaySummary(quitting: Bool) {
        dayEndDraft = nil
        openLog(title: "Итог дня", quitting: quitting)
    }

    /// По карточке последней задачи решили (списали, отказались или она ушла сама) — показываем итог.
    private func draftResolved(_ draft: SegmentDraft) {
        guard let pending = dayEndDraft, pending.id == draft.id else { return }
        openDaySummary(quitting: pending.quitting)
    }

    func startLater() {
        state.untrackedSince = Date()
        save()
    }

    /// `asOf` — когда открыли окно «Забыл переключиться»: от этого момента считаются последние минуты.
    func reassign(lastMinutes minutes: Int, to id: String, asOf: Date) {
        apply { state, config in state.reassign(lastMinutes: minutes, to: id, asOf: asOf, config: config) }
        toast("Перенесено", "\(minutes) мин → \(id). Учёт идёт по нему.")
    }

    func addToPlan(_ issue: Issue) {
        state.remember([issue])
        state.addToPlan(issue.idReadable)
        save()
    }

    func movePlanItem(_ id: String, to target: String) {
        state.movePlanItem(id, to: target)
        save()
    }

    func removeFromPlan(_ id: String) {
        state.removeFromPlan(id)
        save()
    }

    func remember(_ issues: [Issue]) {
        state.remember(issues)
    }

    /// Изменение состояния из других файлов модели (`state` снаружи только для чтения).
    func mutateState(_ change: (inout TrackerState) -> Void) {
        change(&state)
        save()
    }

    func markSyncAttempt() {
        lastSyncAttempt = Date()
    }

    func cachedSearch(_ key: String) -> [Issue]? {
        guard let hit = searchCache[key], Date().timeIntervalSince(hit.date) < 60 else { return nil }
        return hit.issues
    }

    func storeSearch(_ key: String, _ issues: [Issue]) {
        searchCache[key] = (Date(), issues)
    }

    func clearSearchCache() {
        searchCache = [:]
    }

    // MARK: - Карточки списания

    func commitDraft(_ draft: SegmentDraft, comment: String, type: WorkType) {
        state.commit(draft, comment: comment, type: type)
        draftInputs.removeValue(forKey: draft.id)
        save()
        syncSoon()
        draftResolved(draft)
    }

    func discardDraft(_ draft: SegmentDraft) {
        state.discardDraft(id: draft.id)
        draftInputs.removeValue(forKey: draft.id)
        save()
        toast("Не списано", "\(draft.issueId) · \(Fmt.hm(draft.rawMinutes)) отброшено")
        draftResolved(draft)
    }

    // MARK: - Списания за сегодня

    func updateEntry(_ id: UUID, issueId: String, minutes: Int, comment: String) {
        state.updateEntry(id: id, issueId: issueId, minutes: minutes, comment: comment)
        save()
        syncSoon()
    }

    func deleteEntry(_ id: UUID) {
        let hadWorkItem = state.entries.first { $0.id == id }?.workItemId != nil
        state.deleteEntry(id: id)
        save()
        if hadWorkItem { syncSoon() }
    }

    // MARK: - Простой и забытый старт

    var idleThreshold: TimeInterval { TimeInterval(settings.autopauseMinutes * 60) }

    private func tick() {
        now = Date()
        // Проверяем заранее: вызов мутирующего метода уведомил бы наблюдателей, даже если день тот же.
        if state.current == nil, state.planDay.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
            state.rollOver(now: now, calendar: calendar)
            save()
        }
        checkActivity()
        checkReminder()
        checkMorning()
        if state.hasPendingSync, now.timeIntervalSince(lastSyncAttempt) > 30 { syncSoon() }
        if now.timeIntervalSince(lastExternalRefresh) > 5 * 60 { Task { await refreshExternal() } }
    }

    private func checkActivity() {
        guard !isAsleep, !isLocked else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
        )
        let lastInput = now.addingTimeInterval(-idleSeconds)
        if idleSeconds >= idleThreshold {
            if awaySince == nil { awaySince = lastInput }
            return
        }
        if let since = awaySince, idleSeconds < 3 {
            awaySince = nil
            userReturned(awayFrom: since, at: now)
        }
        if awaySince == nil, now.timeIntervalSince(lastActivitySave) > 30 {
            lastActivitySave = now
            state.lastActivity = lastInput
            save()
        }
    }

    /// Сон и блокировка экрана тоже считаются простоем.
    private func wentAway() {
        guard awaySince == nil else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        awaySince = Date().addingTimeInterval(-min(idleSeconds, 60))
        state.lastActivity = awaySince
        save()
    }

    private func userReturned(awayFrom start: Date, at end: Date) {
        guard end.timeIntervalSince(start) >= idleThreshold else { return }
        if endForgottenDay(lastSeen: start, now: end) { return }
        guard let current = state.current else {
            // Отсчёт «без учёта» сбрасывается простоем.
            state.untrackedSince = end
            reminder = nil
            save()
            return
        }
        guard settings.autopauseEnabled else { return }
        presentIdle(IdlePrompt(start: max(start, current.start), end: end, issueId: current.issueId))
    }

    /// День не завершили, а вернулись уже в другой день: день завершается, когда пользователя видели в последний раз.
    /// Карточка по последнему отрезку показывается как обычно. Возвращает `true`, если день завершён.
    private func endForgottenDay(lastSeen: Date, now: Date) -> Bool {
        guard let issueId = state.current?.issueId else { return false }
        var lastSeen = lastSeen
        // С вечера висит «Вы вернулись» — простой из него тоже не списываем.
        if let prompt = idlePrompt, prompt.issueId == issueId { lastSeen = min(lastSeen, prompt.start) }
        guard state.isForgottenDay(lastSeen: lastSeen, now: now, calendar: calendar) else { return false }
        if idlePrompt != nil {
            idlePrompt = nil
            windows.close("idle")
        }
        apply { state, config in state.endForgottenDay(lastSeen: lastSeen, now: now, config: config) }
        reminder = nil
        let day = Fmt.pastDay(lastSeen).map { $0 + " " } ?? ""
        toast("Прошлый рабочий день завершён", "Учёт по \(issueId) остановлен \(day)в \(Fmt.clock(lastSeen))")
        return true
    }

    private func presentIdle(_ prompt: IdlePrompt) {
        if var existing = idlePrompt, existing.issueId == prompt.issueId {
            existing.end = prompt.end
            idlePrompt = existing
        } else {
            idlePrompt = prompt
        }
        openIdle()
    }

    func resolveIdle(_ choice: IdleChoice, continueTracking: Bool) {
        guard let prompt = idlePrompt else { return }
        idlePrompt = nil
        guard state.current?.issueId == prompt.issueId else { return }
        if choice == .endDay {
            endDay(at: prompt.start)
            return
        }
        apply { state, config in
            state.resolveIdle(from: prompt.start, to: prompt.end, choice: choice, continueTracking: continueTracking, config: config)
        }
        if choice == .discard {
            toast("Простой отброшен", "\(TimeMath.minutes(from: prompt.start, to: prompt.end)) мин не списаны")
        }
    }

    private func checkReminder() {
        let blocked = !settings.forgotEnabled || state.current != nil || state.phase == .ended
            || windows.hasOpenWindow || awaySince != nil || now < reminderSnoozedUntil
        guard !blocked else {
            if reminder != nil { reminder = nil }
            return
        }
        let kind: Reminder.Kind = state.phase == .notStarted ? .dayNotStarted : state.paused ? .paused : .untracked
        var since = state.untrackedSince ?? now
        if kind == .dayNotStarted {
            // О начале дня напоминаем только по расписанию и считаем от начала рабочего дня.
            guard settings.schedule.hasBegun(at: now, calendar: calendar) else {
                if reminder != nil { reminder = nil }
                return
            }
            since = max(since, settings.schedule.start(on: now, calendar: calendar))
        }
        let minutes = TimeMath.minutes(from: since, to: now)
        guard minutes >= settings.forgotMinutes else {
            if reminder != nil { reminder = nil }
            return
        }
        let next = Reminder(kind: kind, minutes: minutes, since: since, issueId: state.startCandidate)
        if reminder != next { reminder = next }
    }

    func snoozeReminder() {
        reminderSnoozedUntil = Date().addingTimeInterval(10 * 60)
        reminder = nil
    }

    func startFromReminder(backdated: Bool) {
        guard let reminder, let id = reminder.issueId else { return }
        startIssue(id, at: backdated ? reminder.since : nil)
        if backdated { toast("Учёт начат задним числом", "\(id) · с \(Fmt.clock(reminder.since))") }
    }

    /// Автопоказ начала дня в рабочие дни в заданное время (настройка «Открывать начало дня само»).
    private func checkMorning() {
        guard settings.morningEnabled, state.phase == .notStarted, state.current == nil,
              !windows.hasOpenWindow, awaySince == nil else { return }
        let today = calendar.startOfDay(for: now)
        guard settings.schedule.hasBegun(at: now, calendar: calendar),
              state.lastAutoMorningDay.map({ $0 < today }) ?? true else { return }
        state.lastAutoMorningDay = today
        save()
        startDay(automatically: true)
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (AppModel) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { body(self) }
                }
            })
        }
        on(workspace, NSWorkspace.willPowerOffNotification) { $0.systemIsPoweringOff = true }
        on(workspace, NSWorkspace.willSleepNotification) { $0.wentAway(); $0.isAsleep = true }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.wentAway(); $0.isAsleep = true }
        on(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.isAsleep = false }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.wentAway(); $0.isLocked = true }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
    }

    // MARK: - Уведомления

    func dismissToast(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func toast(_ title: String, _ text: String, isError: Bool = false) {
        let toast = Toast(title: title, text: text, isError: isError)
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 8 : 4.2))
            toasts.removeAll { $0.id == toast.id }
        }
    }

    // MARK: - Система

    func applyHotKey() {
        HotKeyCenter.shared.register(settings.hotKey)
    }

    func applyLaunchAtLogin() {
        // SMAppService работает только для собранного .app, не для `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !settings.launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            toast("Автозапуск не настроен", error.localizedDescription, isError: true)
        }
    }

    func closeMenu() {
        menuBar?.close()
    }
}
