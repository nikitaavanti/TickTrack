import SwiftUI
import TickTrackCore

struct SettingsView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            Form {
                Section("YouTrack") {
                    TextField("Адрес сервера", text: $settings.serverURL, prompt: Text("https://youtrack.example.com"))
                        .onSubmit { Task { await model.checkConnection() } }
                    SecureField("Постоянный токен", text: $settings.token, prompt: Text("perm:…"))
                        .onSubmit { Task { await model.checkConnection() } }
                    TextField("Запрос «в работе у меня»", text: $settings.inProgressQuery)
                    HStack {
                        Button("Проверить подключение") { Task { await model.checkConnection() } }
                        connectionStatus
                    }
                }
                MyProjectsSection(model: model)
                Section {
                    LabeledContent {
                        WorkdaysPicker(selection: $settings.workdays)
                    } label: {
                        HintLabel("Рабочие дни", hint: "В эти дни TickTrack сам предлагает сформировать план на день и напоминает, если учёт не включён. В другие дни учёт работает, только если вы сами начали день.")
                    }
                    // Вручную, а не `DatePicker` со своим названием: у того название съезжает выше поля.
                    HStack {
                        HintLabel("Начало рабочего дня", hint: "Раньше этого времени TickTrack не предлагает сформировать план на день и не напоминает о работе.")
                        Spacer()
                        DatePicker("Начало рабочего дня", selection: morningTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    Toggle(isOn: $settings.morningEnabled) {
                        HintLabel("Формировать план на день в начале дня", hint: "В рабочий день в указанное время откроется «План на день». Если план уже собран — сразу выбор задачи, с которой начать.")
                    }
                } header: {
                    Text("Рабочий день")
                } footer: {
                    Text("В нерабочие дни и до начала рабочего дня TickTrack не предлагает план и не напоминает о работе.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Перерывы и напоминания") {
                    Toggle(isOn: $settings.autopauseEnabled) {
                        HintLabel("Спрашивать, как записать перерыв", hint: "Когда вы вернётесь к компьютеру, TickTrack спросит, что делать со временем перерыва: записать в другую задачу (например, на созвон), в текущую, не записывать или завершить рабочий день. Если выключить, перерыв засчитывается в текущую задачу.")
                    }
                    Stepper(value: $settings.autopauseMinutes, in: 1...120) {
                        HintLabel("Перерыв — от \(settings.autopauseMinutes) мин без мыши и клавиатуры", hint: "Сон Mac и блокировка экрана тоже считаются перерывом.")
                    }
                    Toggle(isOn: $settings.forgotEnabled) {
                        HintLabel("Напоминать, если учёт не ведётся", hint: "Если вы работаете за компьютером, а учёт не ведётся, появится напоминание: начать учёт сейчас или с момента, когда он остановился.")
                    }
                    Stepper(value: $settings.forgotMinutes, in: 1...120) {
                        HintLabel("Через \(settings.forgotMinutes) мин работы без учёта", hint: "Сколько минут работы без учёта ждать перед напоминанием.")
                    }
                    .disabled(!settings.forgotEnabled)
                }
                Section("Списание") {
                    Stepper(value: $settings.minimumMinutes, in: 0...30) {
                        HintLabel("Не списывать активность меньше \(settings.minimumMinutes) мин", hint: "Короткое время по задаче не уходит в YouTrack, например, если вы быстро переключились или нажали не ту задачу. 0 — списывать всё.")
                    }
                    Toggle(isOn: $settings.cardEnabled) {
                        HintLabel("Проверять списание перед отправкой", hint: "После каждой задачи появляется карточка: можно выбрать тип работы, написать комментарий или отказаться от списания. Если выключить, время уходит в YouTrack сразу, без вашего комментария.")
                    }
                    Stepper(value: $settings.cardSeconds, in: 5...120, step: 5) {
                        HintLabel("Если не трогать, отправить через \(settings.cardSeconds) с", hint: "Пока карточку не трогаете, идёт отсчёт. Выбрали тип или начали писать комментарий — карточка ждёт вас.")
                    }
                    .disabled(!settings.cardEnabled)
                    Picker(selection: $settings.defaultType) {
                        ForEach(WorkType.allCases) { Text(verbatim: $0.title).tag($0) }
                    } label: {
                        HintLabel("Тип работы по умолчанию", hint: "Подставляется для задач, по которым ещё не списывали. Дальше для каждой задачи запоминается последний выбранный тип. Тип пишется в начале комментария: «Анализ: …».")
                    }
                    Stepper(value: $settings.dailyNormMinutes, in: 30...(16 * 60), step: 30) {
                        HintLabel("Норма в день: \(settings.dailyNorm.hoursText) ч", hint: "Сколько часов в день вы обычно списываете. В меню и в итоге дня видно, сколько процентов нормы набрано и сколько осталось.")
                    }
                }
                Section("Вид и клавиши") {
                    Picker("В строке меню", selection: $settings.menuBarMode) {
                        ForEach(MenuBarTitleMode.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    LabeledContent("Сочетание для открытия меню") {
                        HotKeyRecorder(shortcut: $settings.hotKey)
                    }
                }
                Section("Система") {
                    Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Завершить TickTrack") { NSApp.terminate(nil) }
                Spacer()
                Button("Готово", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 700)
        .onChange(of: settings.hotKey) { model.applyHotKey() }
        .onChange(of: settings.launchAtLogin) { model.applyLaunchAtLogin() }
        .onChange(of: settings.serverURL) { model.connectionSettingsChanged() }
        .onChange(of: settings.token) { model.connectionSettingsChanged() }
        .task {
            if model.settings.isConfigured, model.connection == .unknown { await model.checkConnection() }
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch model.connection {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .connected(let name):
            Label("Подключено: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
        }
    }

    private var morningTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: model.settings.morningTime / 60, minute: model.settings.morningTime % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.settings.morningTime = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// Название настройки со значком ⓘ: пояснение открывается при наведении на значок и по щелчку.
/// Обычная подсказка (`.help`) не видна, пока её не наведёшь, и не показывается, если приложение не активно.
private struct HintLabel: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey

    init(_ title: LocalizedStringKey, hint: LocalizedStringKey) {
        self.title = title
        self.hint = hint
    }

    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(hovering || shown ? .primary : .secondary)
                .contentShape(Circle())
                .onHover { over in
                    hovering = over
                    if over {
                        // Небольшая задержка: значок не открывает пояснение, когда мышь просто проходит мимо.
                        Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            if hovering { shown = true }
                        }
                    } else {
                        shown = false
                    }
                }
                .onTapGesture { shown.toggle() }
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    Text(hint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(12)
                }
                .accessibilityLabel(Text(hint))
        }
    }
}

/// Дни недели кнопками, с понедельника.
private struct WorkdaysPicker: View {
    @Binding var selection: Set<Int>

    /// Номера дней в `Calendar`: 2 — понедельник … 7 — суббота, 1 — воскресенье.
    private let days: [(weekday: Int, title: LocalizedStringKey)] = [
        (2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"), (6, "Пт"), (7, "Сб"), (1, "Вс"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.weekday) { day in
                let on = selection.contains(day.weekday)
                // Как `ChipButton` в карточке списания: выбранный день закрашен.
                Button {
                    if on { selection.remove(day.weekday) } else { selection.insert(day.weekday) }
                } label: {
                    Text(day.title)
                        .font(.system(size: 11.5))
                        .frame(minWidth: 22)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Поле записи сочетания: нажмите кнопку, затем новое сочетание. Esc — отмена.
struct HotKeyRecorder: View {
    @Binding var shortcut: HotKeyShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Нажмите сочетание…" : shortcut.display) {
            recording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
            } else if let recorded = HotKeyShortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.register(shortcut) }
        recording = false
    }
}

/// «Мои проекты»: поиск, подсказки «в работе» и новые задачи — только в них.
private struct MyProjectsSection: View {
    let model: AppModel

    @State private var filter = ""
    /// Какие проекты были отмечены при открытии настроек: они стоят сверху. Порядок не меняется на ходу,
    /// иначе строка уезжала бы из-под курсора при клике.
    @State private var pinned: [String] = []
    @State private var loading = true

    private var mine: [String] { model.settings.myProjects }

    private func isMine(_ project: Project) -> Bool {
        mine.contains { $0.caseInsensitiveCompare(project.shortName) == .orderedSame }
    }

    /// Отмеченные сверху, дальше по алфавиту; строка фильтра ищет по названию и короткому имени.
    private var shown: [Project] {
        let key = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = key.isEmpty ? model.projects : model.projects.filter {
            $0.name.lowercased().contains(key) || $0.shortName.lowercased().contains(key)
        }
        let isPinned = { (project: Project) in pinned.contains { $0.caseInsensitiveCompare(project.shortName) == .orderedSame } }
        return list.filter(isPinned) + list.filter { !isPinned($0) }
    }

    var body: some View {
        Section {
            if model.projects.isEmpty {
                Group {
                    if !model.settings.isConfigured {
                        Text("Проекты появятся после подключения к YouTrack.")
                    } else if loading {
                        Text("Загружаем проекты…")
                    } else {
                        Text("Не удалось загрузить проекты. Проверьте подключение.")
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                TextField("Найти проект", text: $filter, prompt: Text("Найти проект: название или код"))
                    .labelsHidden()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown) { project in
                            Toggle(isOn: Binding(get: { isMine(project) }, set: { set(project, $0) })) {
                                HStack(spacing: 6) {
                                    Text(verbatim: project.name)
                                    if project.shortName != project.name {
                                        Text(verbatim: project.shortName).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }
        } header: {
            Text("Мои проекты")
        } footer: {
            Text(mine.isEmpty
                 ? "Не выбрано — поиск идёт по всем проектам."
                 : "Поиск, подсказки «в работе» и новые задачи — только в отмеченных проектах (\(mine.count)). Задача по точному ID находится в любом проекте.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: model.settings.isConfigured) {
            loading = true
            await model.loadProjects()
            loading = false
        }
        .onAppear { pinned = mine }
    }

    private func set(_ project: Project, _ on: Bool) {
        var list = mine.filter { $0.caseInsensitiveCompare(project.shortName) != .orderedSame }
        if on { list.append(project.shortName) }
        model.settings.myProjects = list
        model.myProjectsChanged()
    }
}
