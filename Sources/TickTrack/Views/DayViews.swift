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
                section("Вчера в плане", carryOver)
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
                        IssueLine(id: id, title: model.title(of: id))
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
                            IssueLine(id: id, title: model.title(of: id))
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

    private var suggestions: [Issue] {
        model.inProgress.filter { !model.state.plan.contains($0.idReadable) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Задачи, между которыми вы будете переключаться сегодня. В меню у них будут цифры 1–9 для быстрого выбора.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BoxedList {
                if model.state.plan.isEmpty {
                    Text("Пока нет задач. Найдите их в YouTrack ниже.")
                        .foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(model.state.plan.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    HStack {
                        IssueLine(id: id, title: model.title(of: id))
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
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    Text("В работе у вас в YouTrack:").font(.callout).foregroundStyle(.secondary)
                    ForEach(suggestions) { issue in
                        ChipButton(title: "+ " + issue.idReadable) { model.addToPlan(issue) }
                            .help(issue.summary)
                    }
                }
            }
            TextField("Найти задачу в YouTrack: ID или текст", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { add(first) } }
            // Результаты не показываются, пока поле пустое.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                IssueSearchResults(model: model, query: query, results: $results, onPick: add) { text in
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

    private func add(_ issue: Issue) {
        model.addToPlan(issue)
        query = ""
        results = []
        searchFocused = true
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
        let entries = model.todayEntries
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

    private func rows(_ entries: [LogEntry]) -> some View {
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
            ForEach(entries) { entry in
                if editing == entry.id {
                    editor(entry)
                } else {
                    row(entry)
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
