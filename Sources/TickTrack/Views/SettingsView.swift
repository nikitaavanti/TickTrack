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
                Section("Учёт времени") {
                    Toggle("Автопауза при бездействии", isOn: $settings.autopauseEnabled)
                    Stepper("Бездействие дольше \(settings.autopauseMinutes) мин", value: $settings.autopauseMinutes, in: 1...120)
                    Toggle("Напоминать о забытом старте", isOn: $settings.forgotEnabled)
                    Stepper("Если работаю без учёта \(settings.forgotMinutes) мин", value: $settings.forgotMinutes, in: 1...120)
                        .disabled(!settings.forgotEnabled)
                    Toggle("Показывать «Доброе утро» само", isOn: $settings.morningEnabled)
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
