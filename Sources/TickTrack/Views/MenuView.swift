import SwiftUI
import TickTrackCore

/// Пересоздаёт меню при каждом открытии: поиск закрыт, фокус на меню.
struct MenuRoot: View {
    let model: AppModel

    var body: some View {
        MenuView(model: model).id(model.menuSession)
    }
}

struct MenuView: View {
    let model: AppModel

    private enum Focus { case menu, search }

    @State private var searching = false
    @State private var query = ""
    @State private var results: [Issue] = []
    @FocusState private var focus: Focus?

    private var state: TrackerState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            Divider().padding(.vertical, 4)
            planSection
            Divider().padding(.vertical, 4)
            searchSection
            Divider().padding(.vertical, 4)
            if state.current != nil {
                MenuRow(icon: "pause", title: Text("Пауза"), shortcut: "␣") { run(model.pause) }
                MenuRow(icon: "arrow.uturn.backward", title: Text("Я забыл переключиться…")) { run(model.openReassign) }
            }
            if state.current != nil || state.status == .paused {
                MenuRow(icon: "stop", title: Text("Завершить рабочий день")) { run { model.endDay() } }
            }
            if state.current != nil || state.status == .paused {
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
        .frame(width: MenuBarController.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
                    Text(verbatim: current.issueId).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: Fmt.hm(model.elapsedMinutes)).font(.system(size: 15, design: .monospaced)).monospacedDigit()
                }
                Text(verbatim: model.title(of: current.issueId)).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Идёт учёт с \(Fmt.clock(current.start)) · к списанию \(Fmt.hm(model.billableNow))")
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

    private var statusTitle: LocalizedStringKey {
        switch state.status {
        case .paused: "Учёт на паузе"
        case .ended: "Рабочий день завершён"
        case .notStarted: "Рабочий день не начат"
        default: "Учёт не идёт"
        }
    }

    @ViewBuilder private var startButton: some View {
        switch state.status {
        case .notStarted, .ended:
            BigButton(icon: "sun.max.fill", title: "Начать рабочий день", subtitle: "План на день и выбор первой задачи", shortcut: "↵") {
                run(model.openMorning)
            }
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
        ForEach(Array(state.plan.enumerated()), id: \.element) { index, id in
            let spent = model.spentToday(id)
            MenuRow(
                mark: state.current?.issueId == id ? "✓" : "",
                title: Text(verbatim: model.title(of: id).isEmpty ? id : model.title(of: id)),
                subtitle: id + (model.issue(id)?.projectName.isEmpty == false ? " · " + model.issue(id)!.projectName : ""),
                trailing: spent > 0 ? Fmt.hm(spent) : nil,
                shortcut: index < 9 ? String(index + 1) : nil,
                bold: state.current?.issueId == id
            ) { switchTo(id) }
        }
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
                    IssueSearchResults(model: model, query: query, results: $results, onPick: pick) { text in
                        run { model.openCreate(prefill: text) }
                    }
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
                Text("Сегодня списано: ") + Text(verbatim: Fmt.hm(model.totalToday)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
        case .notStarted, .ended: run(model.openMorning)
        case .paused, .idle: if state.startCandidate != nil { run(model.resume) }
        case .tracking: break
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
                    Text(verbatim: subtitle).font(.system(size: 11, design: .monospaced)).opacity(0.9).lineLimit(1)
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
