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
                Section("Учёт времени") {
                    Toggle("Автопауза при бездействии", isOn: $settings.autopauseEnabled)
                    Stepper("Бездействие дольше \(settings.autopauseMinutes) мин", value: $settings.autopauseMinutes, in: 1...120)
                    Toggle("Напоминать о забытом старте", isOn: $settings.forgotEnabled)
                    Stepper("Если работаю без учёта \(settings.forgotMinutes) мин", value: $settings.forgotMinutes, in: 1...120)
                        .disabled(!settings.forgotEnabled)
                    Toggle("Открывать начало дня само", isOn: $settings.morningEnabled)
                    DatePicker("Время", selection: morningTime, displayedComponents: .hourAndMinute)
                        .disabled(!settings.morningEnabled)
                }
                Section("Списание") {
                    Toggle("Округлять вверх до 5 минут", isOn: $settings.roundUpToFive)
                    Stepper("Не списывать отрезки короче \(settings.minimumMinutes) мин", value: $settings.minimumMinutes, in: 0...30)
                    Toggle("Показывать уведомление со списанием", isOn: $settings.cardEnabled)
                    Stepper("Отправлять само через \(settings.cardSeconds) с", value: $settings.cardSeconds, in: 5...120, step: 5)
                        .disabled(!settings.cardEnabled)
                    Picker("Тип работы по умолчанию", selection: $settings.defaultType) {
                        ForEach(WorkType.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    Stepper("Дневная норма \(settings.dailyNorm.hoursText) ч", value: $settings.dailyNormMinutes, in: 30...(16 * 60), step: 30)
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
                model.settings.morningTime = (parts.hour ?? 9) * 60 + (parts.minute ?? 30)
            }
        )
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
                                        Text(verbatim: project.shortName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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
