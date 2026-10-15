import SwiftUI
import TickTrackCore

/// Пересоздаёт меню при каждом открытии: поиск закрыт, фокус на меню.
struct MenuRoot: View {
    let model: AppModel
    let layout: MenuLayout

    var body: some View {
        MenuView(model: model).id(model.menuSession)
            .environment(\.menuMaxHeight, layout.maxHeight)
    }
}

struct MenuView: View {
    let model: AppModel

    private enum Focus { case menu, search }

    @State private var searching = false
    @State private var query = ""
    @State private var results: [Issue] = []
    @FocusState private var focus: Focus?
    @Environment(\.menuMaxHeight) private var maxHeight
    /// Высота всего меню, видимой части списка задач и списка найденных — по ним меню делит место
    /// между двумя списками, а остальное всегда остаётся на экране.
    @State private var menuHeight: CGFloat = 0
    @State private var planHeight: CGFloat = 0
    @State private var resultsHeight: CGFloat = 0

    private var state: TrackerState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            linkStatus
            Divider().padding(.vertical, 4)
            planSection
            Divider().padding(.vertical, 4)
            searchSection
            Divider().padding(.vertical, 4)
            if state.current != nil {
                MenuRow(icon: "stop.circle", title: Text("Остановить учёт"), shortcut: "␣") { run(model.pause) }
                MenuRow(icon: "arrow.uturn.backward", title: Text("Я забыл переключиться…")) { run(model.openReassign) }
            }
            // Пока день начат — и на паузе, и после «Начну позже»: иначе такой день нечем завершить.
            if state.phase == .started {
                MenuRow(icon: "stop.fill", title: Text("Завершить рабочий день")) { run { model.endDay() } }
                Divider().padding(.vertical, 4)
            }
            MenuRow(icon: "list.bullet", title: Text("План на день…")) { run { model.openPlan() } }
            MenuRow(icon: "clock.arrow.circlepath", title: Text("Списания за сегодня…")) { run { model.openLog() } }
            MenuRow(icon: "info.circle", title: Text("О программе TickTrack")) { run(model.openAbout) }
            MenuRow(icon: "gearshape", title: Text("Настройки…"), shortcut: "⌘,") { run { model.openSettings() } }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(icon: "power", title: Text("Завершить TickTrack"), shortcut: "⌘Q") {
                // Решение (спросить или выйти сразу) принимает applicationShouldTerminate.
                run { NSApp.terminate(nil) }
            }
            .keyboardShortcut("q", modifiers: .command)
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(6)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { menuHeight = $0 }
        .frame(width: MenuBarController.width)
        .glassEffect(.regular, in: .rect(cornerRadius: MenuBarController.cornerRadius))
        .focusable()
        .focused($focus, equals: .menu)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear { focus = .menu }
    }

    // MARK: - Шапка

    @ViewBuilder private var header: some View {
        if let current = state.current {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    StatusDot(indicator: .running)
                    IssueIDLink(model: model, id: current.issueId).foregroundStyle(.secondary)
                    Spacer()
                    BlinkingTime(minutes: model.elapsedMinutes, colonVisible: Int(model.now.timeIntervalSince(current.start)) % 2 == 0)
                        .font(.system(size: 15).monospacedDigit())
                }
                Text(verbatim: model.title(of: current.issueId)).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .issueContextMenu(model, current.issueId)
                Text("Идёт учёт с \(Fmt.clock(current.start))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(indicator: model.indicator)
                    Text(statusTitle).font(.system(size: 13.5, weight: .semibold))
                }
                startButton
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    /// Нет связи с YouTrack: видно всё время, пока её нет, и с очередью, и без неё.
    @ViewBuilder private var linkStatus: some View {
        if let problem = model.link.problem {
            HStack(spacing: 8) {
                Image(systemName: problem == .noNetwork ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    (problem == .tokenRejected ? Text("YouTrack не принял токен") : Text("Нет связи с YouTrack"))
                        .font(.system(size: 12.5, weight: .semibold))
                    linkDetails(problem).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if problem == .tokenRejected {
                    Button("Настройки") { run { model.openSettings() } }
                } else {
                    Button(model.linkRetrying ? "Проверяем…" : "Повторить", action: model.retryLink)
                        .disabled(model.linkRetrying)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func linkDetails(_ problem: LinkProblem) -> Text {
        if let pending = model.pendingSummary {
            return Text("\(pending.phrase) \(pending.verb("ждёт", "ждут")) отправки · \(Fmt.hm(pending.minutes))")
        }
        return switch problem {
        case .noNetwork: Text("Mac не подключён к сети. Поиск — среди известных задач")
        case .notResponding: Text("YouTrack не отвечает. Поиск — среди известных задач")
        case .tokenRejected: Text("Укажите новый токен в настройках")
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch state.status {
        case .paused: "Учёт остановлен"
        case .ended: "Рабочий день завершён"
        case .notStarted: "Рабочий день не начат"
        default: "Учёт не идёт"
        }
    }

    @ViewBuilder private var startButton: some View {
        switch state.status {
        case .notStarted, .ended:
            BigButton(
                icon: "sun.max.fill", title: "Начать рабочий день",
                subtitle: state.plan.isEmpty ? "План на день и выбор первой задачи" : "Выбор первой задачи", shortcut: "↵"
            ) { run { model.startDay() } }
        default:
            if let id = state.startCandidate {
                BigButton(
                    icon: "play.fill", title: state.status == .paused ? "Продолжить работу" : "Начать работу",
                    subtitle: id + " · " + Fmt.short(model.title(of: id), 34), shortcut: "↵"
                ) { run(model.resume) }
                Text("Или выберите другую задачу в списке ниже").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                BigButton(icon: "plus", title: "Составить план на день", subtitle: "Добавьте задачи, чтобы начать учёт", shortcut: nil) {
                    run { model.openPlan() }
                }
            }
        }
    }

    // MARK: - План

    @ViewBuilder private var planSection: some View {
        SectionLabel("Задачи на сегодня")
        if state.plan.isEmpty {
            Text("Список пуст. Добавьте задачу через поиск ниже.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
        }
        // Длинный план прокручивается, а шапка и команды ниже остаются на экране.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(state.plan.enumerated()), id: \.element) { index, id in
                        let spent = model.spentToday(id)
                        MenuRow(
                            mark: state.current?.issueId == id ? "✓" : "",
                            title: Text(verbatim: model.title(of: id).isEmpty ? id : model.title(of: id)),
                            subtitle: id,
                            issueLink: (model, id),
                            trailing: spent > 0 ? Fmt.hm(spent) : nil,
                            shortcut: index < 9 ? String(index + 1) : nil,
                            bold: state.current?.issueId == id
                        ) {
                            if model.isCommandClick { model.openInYouTrack(id) } else { switchTo(id) }
                        }
                        .issueContextMenu(model, id)
                        .id(id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .thinScrollIndicator()
            .frame(maxHeight: planMaxHeight)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { planHeight = $0 }
            .onAppear {
                if let id = state.current?.issueId ?? state.startCandidate { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Видны ли в меню найденные задачи.
    private var showsResults: Bool {
        searching && !query.trimmingCharacters(in: .whitespaces).isEmpty && !results.isEmpty
    }

    /// Место под оба списка — задачи на сегодня и найденные: экран минус все остальные части меню.
    /// Пара точек запаса: из-за округления меню не должно оказаться выше панели, иначе срежутся скруглённые углы.
    private var listsRoom: CGFloat {
        maxHeight - (menuHeight - planHeight - (showsResults ? resultsHeight : 0)) - 2
    }

    /// Сколько места список задач оставляет за собой: обычно три строки, а пока видны найденные — две с половиной,
    /// чтобы было видно, что он прокручивается. Короткому плану — по числу его задач.
    private var planMinHeight: CGFloat {
        let rows = CGFloat(state.plan.count) * IssueSearchResults.rowHeight
        return showsResults ? min(rows, 2.5 * IssueSearchResults.rowHeight) : 120
    }

    /// Место для списка задач: всё, что осталось от экрана после остальных частей меню, но не меньше `planMinHeight`.
    /// Пока меню не измерено, список ограничен половиной экрана: иначе меню на миг вылезет за край
    /// и окажется обрезанным снизу.
    private var planMaxHeight: CGFloat {
        guard maxHeight.isFinite else { return .infinity }
        guard menuHeight > 0 else { return max(maxHeight / 2, 120) }
        return max(listsRoom - (showsResults ? resultsHeight : 0), planMinHeight)
    }

    /// Сколько найденных задач видно без прокрутки: сколько влезает после списка задач.
    /// Пять точек — на разделитель под прокручиваемым списком.
    private var searchVisibleRows: Int? {
        guard maxHeight.isFinite, menuHeight > 0 else { return nil }
        let rows = (listsRoom - planMinHeight - 5) / IssueSearchResults.rowHeight - 0.5
        return max(Int(rows.rounded(.down)), 2)
    }

    // MARK: - Поиск

    @ViewBuilder private var searchSection: some View {
        if searching {
            VStack(alignment: .leading, spacing: 4) {
                TextField("ID или название — можно начать печатать прямо в меню", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onSubmit(pickFirst)
                    .onExitCommand(perform: closeSearch)
                    .padding(.horizontal, 4)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    IssueSearchResults(
                        model: model, query: query, results: $results, visibleRows: searchVisibleRows, onPick: pick,
                        onCreate: { text in run { model.openCreate(prefill: text) } },
                        onListHeight: { resultsHeight = $0 }
                    )
                }
                Text("↵ — начать первую найденную").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            .padding(.vertical, 2)
        } else {
            MenuRow(icon: "magnifyingglass", title: Text("Другая задача из YouTrack…"), hint: "Поиск по ID или названию", shortcut: "⌘F") {
                openSearch("")
            }
            .keyboardShortcut("f", modifiers: .command)
            MenuRow(icon: "plus", title: Text("Новая задача в YouTrack…"), hint: "Создать и сразу начать учёт", shortcut: "⌘N") {
                run { model.openCreate(prefill: "") }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Сегодня списано: ") + Text(verbatim: Fmt.hm(model.totalToday)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                Spacer()
                Text("Открыть меню: ") + Text(verbatim: model.settings.hotKey.display).fontWeight(.semibold)
            }
            normText(model)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Действия

    private func run(_ action: @escaping () -> Void) {
        model.closeMenu()
        action()
    }

    private func switchTo(_ id: String) {
        model.startIssue(id)
        model.closeMenu()
    }

    private func pick(_ issue: Issue) {
        model.remember([issue])
        switchTo(issue.idReadable)
    }

    private func pickFirst() {
        if let first = results.first { pick(first) }
    }

    private func openSearch(_ prefix: String) {
        query = prefix
        results = []
        searching = true
        focus = .search
        model.menuBar?.moveCaretToEnd()
    }

    private func closeSearch() {
        searching = false
        query = ""
        focus = .menu
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // В поле ввода клавиши меню не перехватываем.
        if focus == .search { return .ignored }
        if press.key == .escape {
            model.closeMenu()
            return .handled
        }
        if !press.modifiers.intersection([.command, .control, .option]).isEmpty { return .ignored }
        switch press.key {
        case .return:
            primaryAction()
            return .handled
        case .space:
            if state.current != nil { run(model.pause) }
            return .handled
        default:
            break
        }
        guard let character = press.characters.first else { return .ignored }
        if let digit = character.wholeNumberValue, (1...9).contains(digit) {
            if digit <= state.plan.count { switchTo(state.plan[digit - 1]) }
            return .handled
        }
        if character.isLetter {
            openSearch(String(character))
            return .handled
        }
        return .ignored
    }

    private func primaryAction() {
        switch state.status {
        case .notStarted, .ended: run { model.startDay() }
        case .paused, .idle: if state.startCandidate != nil { run(model.resume) }
        case .tracking: break
        }
    }
}

/// Таймер `ч:мм`, у которого раз в секунду мигает двоеточие: видно, что отсчёт идёт.
/// Двоеточие становится прозрачным, а не пропадает, чтобы цифры не сдвигались.
private struct BlinkingTime: View {
    let minutes: Int
    let colonVisible: Bool

    var body: some View {
        let parts = Fmt.hm(minutes).split(separator: ":", maxSplits: 1).map(String.init)
        HStack(spacing: 0) {
            Text(verbatim: parts.first ?? "")
            Text(verbatim: ":").opacity(colonVisible ? 1 : 0)
            Text(verbatim: parts.count > 1 ? parts[1] : "")
        }
    }
}

/// Крупная кнопка начала работы в шапке меню.
private struct BigButton: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.22)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(verbatim: subtitle).font(.system(size: 11).monospacedDigit()).opacity(0.9).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let shortcut { Text(verbatim: shortcut).font(.system(size: 11.5)).opacity(0.85) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.green).interactive(), in: .rect(cornerRadius: 10))
    }
}
