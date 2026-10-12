import SwiftUI
import TickTrackCore

/// «Доброе утро»: что берём в план на сегодня.
struct MorningView: View {
    let model: AppModel
    let close: () -> Void

    @State private var unchecked: Set<String> = []
    private let carryOver: [String]

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        carryOver = model.state.morningCarryOver
    }

    private var inProgress: [String] {
        model.inProgress.map(\.idReadable).filter { !carryOver.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Что берём в план на сегодня?").font(.title3.weight(.semibold))
            if !carryOver.isEmpty {
                // План могли собрать ещё до начала дня: тогда это сегодняшние задачи, а не вчерашние.
                section(model.state.plan.isEmpty ? "Вчера в плане" : "Уже в плане", carryOver)
            }
            if model.inProgressLoading && model.inProgress.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Загружаем задачи «в работе»…").foregroundStyle(.secondary) }
            } else if !inProgress.isEmpty {
                section("В работе у вас в YouTrack", inProgress)
            }
            if carryOver.isEmpty && inProgress.isEmpty && !model.inProgressLoading {
                Text("Предложить нечего: вчерашнего плана нет, задач «в работе» не найдено.").foregroundStyle(.secondary)
            }
            Text("Снимите лишние галочки. На следующем шаге список можно дополнить поиском.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Собрать с нуля") {
                    model.beginDay(plan: [])
                    close()
                    model.openPlan(then: { [model] in model.openStartWork() })
                }
                Button("Взять выбранные") {
                    model.beginDay(plan: (carryOver + inProgress).filter { !unchecked.contains($0) })
                    close()
                    model.openStartWork()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func section(_ title: LocalizedStringKey, _ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            BoxedList {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    Toggle(isOn: Binding(
                        get: { !unchecked.contains(id) },
                        set: { if $0 { unchecked.remove(id) } else { unchecked.insert(id) } }
                    )) {
                        IssueLine(id: id, title: model.title(of: id), unavailable: model.unavailableIssues.contains(id))
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// «Начало работы»: с какой задачи начинаете.
struct StartWorkView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("С какой задачи начинаете?").font(.title3.weight(.semibold))
            Text("Учёт пойдёт с этой минуты. Тип работы и комментарий спросим уведомлением, когда переключитесь на другую задачу.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BoxedList {
                ForEach(Array(model.state.plan.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    Button {
                        close()
                        model.startIssue(id)
                        model.toast("Учёт начат", "\(id) · с \(Fmt.clock(Date()))")
                    } label: {
                        HStack {
                            IssueLine(id: id, title: model.title(of: id), unavailable: model.unavailableIssues.contains(id))
                            Spacer()
                            Label("Начать", systemImage: "play.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Дополнить план…") {
                    close()
                    model.openPlan(then: { [model] in model.openStartWork() })
                }
                .buttonStyle(.link)
                Spacer()
                Button("Начну позже") {
                    close()
                    model.startLater()
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// «План на день».
struct PlanView: View {
    let model: AppModel
    let continues: Bool
    let close: () -> Void

    @State private var query = ""
    @State private var results: [Issue] = []
    @FocusState private var searchFocused: Bool

    private var previous: [String] { model.state.previousPlanSuggestions }

    private var suggestions: [Issue] {
        model.inProgress.filter { !model.state.plan.contains($0.idReadable) && !previous.contains($0.idReadable) }
    }

    /// Перетаскиваемая задача: пока её тянут, план переставляется на лету.
    @State private var dragging: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Соберите задачи, над которыми будете работать сегодня.").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("Они появятся в меню TickTrack, и переключаться между ними можно будет одним нажатием: откройте меню (\(model.settings.hotKey.display)) и нажмите цифру задачи или кликните по ней.")
                Text("Цифры идут по порядку: верхняя задача — 1, следующая — 2, и так до 9. Перетащите задачу мышкой, чтобы поменять порядок.")
            }
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BoxedList {
                if model.state.plan.isEmpty {
                    Text("Пока нет задач.")
                        .foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(model.state.plan.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    planRow(id, index: index)
                }
            }
            Text("Добавить задачу: найдите её в YouTrack по ID или названию или возьмите из тех, что у вас в работе.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Пока идёт поиск, подсказки убираем: место нужно результатам, окно не растёт за край экрана.
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestionTable
            }
            TextField("Найти задачу в YouTrack: ID или текст", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { add(first) } }
            // Результаты не показываются, пока поле пустое.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                IssueSearchResults(model: model, query: query, results: $results, limit: 20, visibleRows: 5, onPick: add) { text in
                    model.openCreate(prefill: text, fromPlan: true)
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            }
            HStack {
                Spacer()
                Button(continues ? "Готово, дальше" : "Готово", action: close)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.loadInProgress() }
    }

    private func planRow(_ id: String, index: Int) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            IssueLine(id: id, title: model.title(of: id), unavailable: model.unavailableIssues.contains(id))
            Spacer()
            if let project = model.issue(id)?.projectName, !project.isEmpty {
                Text(verbatim: project).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Button {
                model.removeFromPlan(id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать из списка")
            // Цифра, как в меню: у десятой задачи и дальше её нет.
            Text(verbatim: index < 9 ? String(index + 1) : "")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(dragging == id ? 0.4 : 1)
        .onDrag {
            dragging = id
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [.text], delegate: PlanDropDelegate(target: id, dragging: $dragging, model: model))
    }

    private var previousIssues: [Issue] {
        previous.map { model.issue($0) ?? Issue(idReadable: $0, summary: "") }
    }

    /// Подсказки одной таблицей: вчерашний план и задачи «в работе». Длинный список прокручивается.
    @ViewBuilder private var suggestionTable: some View {
        let lines = (previous.isEmpty ? 0 : previous.count + 1) + (suggestions.isEmpty ? 0 : suggestions.count + 1)
        if lines > 0 {
            let table = VStack(spacing: 0) {
                if !previous.isEmpty { suggestionGroup("Вчера в плане", previousIssues) }
                if !suggestions.isEmpty {
                    if !previous.isEmpty { Divider() }
                    suggestionGroup("В работе у вас в YouTrack", suggestions)
                }
            }
            BoxedList {
                if lines > 7 {
                    ScrollView { table }.frame(height: 210)
                } else {
                    table
                }
            }
        }
    }

    private func suggestionGroup(_ title: LocalizedStringKey, _ issues: [Issue]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if issues.count > 1 {
                    Button("Добавить все") { for issue in issues { model.addToPlan(issue) } }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(issues) { issue in
                Divider()
                Button {
                    model.addToPlan(issue)
                } label: {
                    HStack {
                        IssueLine(id: issue.idReadable, title: model.title(of: issue.idReadable), unavailable: model.unavailableIssues.contains(issue.idReadable))
                        Spacer()
                        if !issue.projectName.isEmpty {
                            Text(verbatim: issue.projectName).font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Добавить в план")
            }
        }
    }

    private func add(_ issue: Issue) {
        model.addToPlan(issue)
        query = ""
        results = []
        searchFocused = true
    }
}

/// Перестановка задач плана перетаскиванием: задача встаёт на место той, над которой её держат.
private struct PlanDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.movePlanItem(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// «Списания за сегодня» и «Итог дня».
struct LogView: View {
    let model: AppModel
    var quitting = false
    let close: () -> Void

    @State private var leaving = false

    @State private var editing: UUID?
    @State private var editIssue = ""
    @State private var editMinutes = 0
    @State private var editComment = ""

    var body: some View {
        let entries = model.todayRows
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                Text("Сегодня ещё ничего не списано.").foregroundStyle(.secondary)
            } else if entries.count > 6 {
                ScrollView { rows(entries) }.frame(height: 380)
            } else {
                rows(entries)
            }
            if !model.state.drafts.isEmpty {
                Text("Ещё \(model.state.drafts.count) ждут решения в уведомлениях справа вверху.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Итого списано").foregroundStyle(.secondary)
                Text(verbatim: Fmt.hm(model.totalToday)).font(.system(size: 24, weight: .semibold, design: .monospaced))
                normText(model, showingNorm: true).foregroundStyle(.secondary)
            }
            Text("Правка и удаление сразу меняют запись в YouTrack.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if quitting {
                    if leaving {
                        ProgressView().controlSize(.small)
                        Text("Отправляем в YouTrack…").foregroundStyle(.secondary)
                    }
                    Button("Выйти") {
                        leaving = true
                        Task { await model.finishQuit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(leaving)
                } else {
                    Button("Закрыть", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func rows(_ entries: [LogRow]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Конец").frame(width: 50, alignment: .leading)
                Text("Задача и комментарий")
                Spacer()
                Text("Время")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.trailing, 80).padding(.bottom, 4)
            Divider()
            ForEach(entries) { item in
                switch item {
                case .local(let entry):
                    if editing == entry.id {
                        editor(entry)
                    } else {
                        row(entry)
                    }
                case .external(let external):
                    externalRow(external)
                }
                Divider()
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: Fmt.clock(entry.end)).font(.system(size: 12.5, design: .monospaced)).frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.issueId).font(.system(size: 11.5, design: .monospaced))
                Text(verbatim: entry.comment).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if entry.sync != .synced {
                    Group {
                        if let error = entry.lastError { Text("ждёт отправки · \(error)") } else { Text("ждёт отправки") }
                    }
                    .font(.caption).foregroundStyle(entry.lastError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(verbatim: Fmt.hm(entry.minutes)).font(.system(size: 12.5, design: .monospaced))
            Button("Изменить") { beginEdit(entry) }.buttonStyle(.link).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// Списание, сделанное прямо в YouTrack: только просмотр, править его пока можно в самом YouTrack.
    private func externalRow(_ item: ExternalWorkItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "—").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.issueId).font(.system(size: 11.5, design: .monospaced))
                if !item.text.isEmpty {
                    Text(verbatim: item.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(verbatim: Fmt.hm(item.minutes)).font(.system(size: 12.5, design: .monospaced))
            Text("из YouTrack").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                .help("Списано напрямую в YouTrack. Изменить или удалить его можно там.")
        }
        .padding(.vertical, 6)
    }

    private func editor(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                IssuePicker(title: "Задача", selection: $editIssue, issues: model.pickableIssues(including: entry.issueId))
                TextField("Минут", value: $editMinutes, format: .number)
                TextField("Комментарий", text: $editComment)
            }
            HStack {
                Button("Удалить", role: .destructive) {
                    editing = nil
                    model.deleteEntry(entry.id)
                }
                Spacer()
                Button("Отмена") { editing = nil }
                Button("Сохранить") {
                    let comment = editComment.trimmingCharacters(in: .whitespaces)
                    model.updateEntry(entry.id, issueId: editIssue, minutes: max(1, editMinutes), comment: comment.isEmpty ? entry.comment : comment)
                    editing = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .padding(.vertical, 4)
    }

    private func beginEdit(_ entry: LogEntry) {
        editIssue = entry.issueId
        editMinutes = entry.minutes
        editComment = entry.comment
        editing = entry.id
    }
}
