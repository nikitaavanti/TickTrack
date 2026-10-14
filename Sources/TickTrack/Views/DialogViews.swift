import SwiftUI
import TickTrackCore

/// «Я забыл переключиться…»: последние N минут переносятся на другую задачу.
/// Задача выбирается из плана на сегодня (кроме текущей) или находится поиском по YouTrack.
struct ReassignView: View {
    let model: AppModel
    let close: () -> Void

    @State private var minutes: Int
    @State private var target: String
    /// Задача не из плана, найденная поиском: стоит в списке первой.
    @State private var found: Issue?
    @State private var query = ""
    @State private var results: [Issue] = []
    private let maximum: Int
    private let current: ActiveSegment?
    /// Когда открыли окно. «Последние N минут» считаются от этого момента, а не от нажатия «Перенести»:
    /// пока решали, время идёт, и оно должно уйти новой задаче.
    private let openedAt: Date

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let now = Date()
        openedAt = now
        current = model.state.current
        let elapsed = model.state.elapsedMinutes(at: now)
        maximum = max(1, elapsed)
        _minutes = State(initialValue: min(15, max(1, elapsed)))
        _target = State(initialValue: model.state.plan.first { $0 != model.state.current?.issueId } ?? "")
    }

    private var planChoices: [String] {
        model.state.plan.filter { $0 != current?.issueId }
    }

    /// Строки выбора: найденная поиском задача (если её нет в плане), затем план.
    private var choices: [String] {
        guard let found, !planChoices.contains(found.idReadable) else { return planChoices }
        return [found.idReadable] + planChoices
    }

    private var chosenMinutes: Int { min(maximum, max(1, minutes)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current {
                Text("Учёт идёт по \(current.issueId) с \(Fmt.clock(current.start)). Если последние минуты вы уже работали над другой задачей, перенесите их туда.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Последние, мин")
                    TextField("", value: $minutes, format: .number).frame(width: 60).labelsHidden()
                    Stepper("", value: $minutes, in: 1...maximum).labelsHidden()
                    Text("из \(maximum)").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("На задачу").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if choices.isEmpty {
                        Text("В плане на сегодня других задач нет. Найдите задачу в YouTrack.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        BoxedList {
                            if choices.count > 6 {
                                ScrollView { choiceRows }.frame(height: 6.5 * 35)
                            } else {
                                choiceRows
                            }
                        }
                    }
                }
                TextField("Другая задача из YouTrack: ID или текст", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = results.first { pick(first) } }
                // Результаты не показываются, пока поле пустое.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    IssueSearchResults(model: model, query: query, results: $results, limit: 20, visibleRows: 4, onPick: pick, excluding: current.issueId)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                }
                summary(current)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button("Перенести") {
                    model.reassign(lastMinutes: chosenMinutes, to: target, asOf: openedAt)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty || target == current?.issueId || model.state.current?.issueId != current?.issueId)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Что произойдёт: с какого времени учёт пойдёт по выбранной задаче.
    private func summary(_ current: ActiveSegment) -> Text {
        if chosenMinutes >= maximum {
            return Text("Всё время с \(Fmt.clock(current.start)) перейдёт на выбранную задачу, по \(current.issueId) ничего не спишется.")
        }
        let boundary = Fmt.clock(openedAt.addingTimeInterval(-Double(chosenMinutes) * 60))
        return Text("По \(current.issueId) спишется время до \(boundary), с \(boundary) учёт пойдёт по выбранной задаче.")
    }

    private var choiceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element) { index, id in
                if index > 0 { Divider() }
                Button {
                    target = id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: target == id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(target == id ? Color.accentColor : Color.secondary)
                        IssueLine(model: model, id: id, title: model.title(of: id), unavailable: model.unavailableIssues.contains(id))
                        Spacer()
                        if found?.idReadable == id && !planChoices.contains(id) {
                            Text("из поиска").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .issueContextMenu(model, id)
            }
        }
    }

    /// Текущей задачи в результатах поиска нет: переносить время на неё же бессмысленно.
    private func pick(_ issue: Issue) {
        guard issue.idReadable != current?.issueId else { return }
        model.remember([issue])
        found = issue
        target = issue.idReadable
        query = ""
        results = []
    }
}

/// «Новая задача в YouTrack».
struct CreateIssueView: View {
    let model: AppModel
    let close: () -> Void

    @State private var title: String
    @State private var projectId: String
    @State private var details = ""
    @State private var assignToMe = true
    @State private var startTracking: Bool
    @State private var minutesAgo = 0
    @State private var error: String?
    @State private var busy = false
    @FocusState private var titleFocused: Bool

    init(model: AppModel, prefill: String, fromPlan: Bool, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _title = State(initialValue: prefill)
        _projectId = State(initialValue: model.defaultProjectId ?? "")
        _startTracking = State(initialValue: !fromPlan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Название", text: $title, prompt: Text("Например: созвон по программе лояльности"))
                    .focused($titleFocused)
                    .onSubmit(create)
                Picker("Проект", selection: $projectId) {
                    if projectId.isEmpty { Text("Выберите проект").tag("") }
                    ForEach(model.projectsForNewIssue) { project in
                        Text(verbatim: "\(project.name) (\(project.shortName))").tag(project.id)
                    }
                }
                TextField("Описание", text: $details, prompt: Text("Необязательно: кто позвал, о чём речь"), axis: .vertical)
                    .lineLimit(3...6)
                Toggle("Назначить на меня", isOn: $assignToMe)
                Toggle("Сразу начать учёт", isOn: $startTracking)
                if startTracking {
                    LabeledContent("Учёт с") {
                        HStack {
                            TextField("", value: $minutesAgo, format: .number).frame(width: 60).labelsHidden()
                            Text("мин назад")
                        }
                    }
                }
            }
            if let error {
                Text(verbatim: error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if startTracking, let current = model.state.current {
                Text("Учёт по \(current.issueId) остановится, по нему придёт уведомление со списанием.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Задача появится в плане на сегодня.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button(startTracking ? "Создать и начать" : "Создать", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            titleFocused = true
            await model.loadProjects()
            // Последний проект мог не входить в «Мои проекты» — тогда первый из них.
            if !model.projectsForNewIssue.contains(where: { $0.id == projectId }), let first = model.projectsForNewIssue.first { projectId = first.id }
        }
    }

    private func create() {
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            error = "Введите название задачи, без него YouTrack её не создаст."
            titleFocused = true
            return
        }
        guard !projectId.isEmpty else {
            error = "Выберите проект."
            return
        }
        error = nil
        busy = true
        Task {
            do {
                try await model.createIssue(
                    summary: summary, projectId: projectId, description: details.trimmingCharacters(in: .whitespacesAndNewlines),
                    assignToMe: assignToMe, startTracking: startTracking, minutesAgo: minutesAgo
                )
                close()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// «Вы вернулись»: что сделать со временем простоя.
struct IdleReturnView: View {
    let model: AppModel
    let prompt: IdlePrompt
    let close: () -> Void

    private enum Choice { case other, keep, discard, endDay }

    @State private var choice: Choice = .other
    @State private var other: String
    @State private var continueTracking = true

    init(model: AppModel, prompt: IdlePrompt, close: @escaping () -> Void) {
        self.model = model
        self.prompt = prompt
        self.close = close
        // По умолчанию — задача, на которую в прошлый раз списывали простой, иначе первая задача плана.
        let candidates = model.pickableIssues(excluding: prompt.issueId).map(\.idReadable)
        let last = model.state.lastIdleIssueId.flatMap { candidates.contains($0) ? $0 : nil }
        _other = State(initialValue: last ?? model.state.plan.first { $0 != prompt.issueId } ?? candidates.first ?? "")
        // Долго не было — скорее всего, ушёл домой.
        let idleMinutes = TimeMath.minutes(from: prompt.start, to: prompt.end)
        _choice = State(initialValue: IdleRules.suggestsEndingDay(idleMinutes: idleMinutes) ? .endDay : .other)
    }

    private var minutes: Int { TimeMath.minutes(from: prompt.start, to: model.idlePrompt?.end ?? prompt.end) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вас не было \(minutes) минут").font(.title3.weight(.semibold))
            Text("С \(Fmt.clock(prompt.start)) до \(Fmt.clock(model.idlePrompt?.end ?? prompt.end)) компьютер не использовался.")
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                option(.other, "Засчитать в другую задачу", "Например, были на созвоне без компьютера") {
                    IssuePicker(title: "Задача", selection: $other, issues: model.pickableIssues(excluding: prompt.issueId))
                        .labelsHidden()
                        .disabled(choice != .other)
                }
                option(.keep, "Засчитать в текущую", "Время пойдёт в \(prompt.issueId)") { EmptyView() }
                option(.discard, "Отбросить", "Учёт по \(prompt.issueId) остановится в \(Fmt.clock(prompt.start))") { EmptyView() }
                option(.endDay, "Завершить рабочий день в \(Fmt.clock(prompt.start))", "Простой не засчитается, откроется итог дня") { EmptyView() }
            }
            if choice != .endDay {
                Toggle("Продолжить учёт по \(prompt.issueId)", isOn: $continueTracking).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Применить", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(choice == .other && other.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func option<Extra: View>(_ value: Choice, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, @ViewBuilder extra: () -> Extra) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    extra()
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(choice == value ? Color.accentColor : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    private func apply() {
        let decision: IdleChoice = switch choice {
        case .other: .otherIssue(other)
        case .keep: .keepCurrent
        case .discard: .discard
        case .endDay: .endDay
        }
        model.resolveIdle(decision, continueTracking: continueTracking)
        close()
    }
}
