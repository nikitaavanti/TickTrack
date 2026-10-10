import AppKit
import SwiftUI
import TickTrackCore

/// Обычные окна приложения (настройки, «Доброе утро» и т. д.). Окна независимы друг от друга.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    var hasOpenWindow: Bool { windows.values.contains { $0.isVisible } }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }

    func show<Content: View>(_ id: String, title: String, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        let controller = NSHostingController(rootView: AnyView(content()))
        controller.sizingOptions = .preferredContentSize
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
            window.contentViewController = controller
        } else {
            window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier(id)
            window.delegate = self
            windows[id] = window
            window.center()
        }
        window.title = title
        closeHandlers[id] = onClose
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
        closeHandlers.removeValue(forKey: id)?()
    }
}

/// Открытие окон из модели.
extension AppModel {
    private func closer(_ id: String) -> () -> Void {
        { [weak self] in self?.windows.close(id) }
    }

    func openMorning() {
        closeMenu()
        reminder = nil
        Task { await loadInProgress(force: true) }
        windows.show("morning", title: "Доброе утро") {
            MorningView(model: self, close: closer("morning"))
        }
    }

    func openStartWork() {
        guard !state.plan.isEmpty else {
            toast("План пуст", "Добавьте задачи через «План на день», затем начните работу из меню")
            return
        }
        windows.show("start", title: "Начало работы") {
            StartWorkView(model: self, close: closer("start"))
        }
    }

    /// `then` вызывается после закрытия окна плана: так «Собрать с нуля» и «Дополнить план…» ведут дальше.
    func openPlan(then next: (() -> Void)? = nil) {
        closeMenu()
        windows.show("plan", title: "План на день", onClose: next) {
            PlanView(model: self, continues: next != nil, close: closer("plan"))
        }
    }

    /// `quitting` — «Итог дня» перед выходом: вместо «Закрыть» кнопка «Выйти».
    func openLog(title: String = "Списания за сегодня", quitting: Bool = false) {
        closeMenu()
        windows.show("log", title: title) {
            LogView(model: self, quitting: quitting, close: closer("log"))
        }
    }

    func openAbout() {
        closeMenu()
        windows.show("about", title: "О программе TickTrack") {
            AboutView()
        }
    }

    func openSettings() {
        closeMenu()
        windows.show("settings", title: "Настройки") {
            SettingsView(model: self, close: closer("settings"))
        }
    }

    func openReassign() {
        closeMenu()
        guard let current = state.current else { return }
        guard elapsedMinutes >= 1 else {
            toast("Нечего переносить", "Учёт по \(current.issueId) идёт меньше минуты")
            return
        }
        windows.show("reassign", title: "Забыл переключиться") {
            ReassignView(model: self, close: closer("reassign"))
        }
    }

    func openCreate(prefill: String, fromPlan: Bool = false) {
        closeMenu()
        windows.show("create", title: "Новая задача в YouTrack") {
            CreateIssueView(model: self, prefill: prefill, fromPlan: fromPlan, close: closer("create"))
        }
    }

    func openIdle() {
        guard let prompt = idlePrompt else { return }
        windows.show("idle", title: "Вы вернулись", onClose: { [weak self] in self?.idlePrompt = nil }) {
            IdleReturnView(model: self, prompt: prompt, close: closer("idle"))
        }
    }
}

// MARK: - Плавающие панели

/// Панель, которая принимает клавиатуру, но не активирует приложение и не уводит фокус у текущей программы.
final class FloatingPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        self.level = level
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Сообщает высоту содержимого, чтобы панель подстраивалась под него.
struct HeightReporting<Content: View>: View {
    let onHeight: (CGFloat) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { onHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in onHeight(height) }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Стопка карточек списания, напоминаний и подтверждений в правом верхнем углу экрана.
final class CardPanelController {
    private let panel = FloatingPanel(level: .statusBar)
    private let model: AppModel
    static let width: CGFloat = 370

    init(model: AppModel) {
        self.model = model
        let host = NSHostingView(rootView: HeightReporting(onHeight: { [weak self] in self?.layout(height: $0) }) {
            CardStackView(model: model)
        })
        host.sizingOptions = []
        panel.contentView = host
    }

    private func layout(height: CGFloat) {
        let isEmpty = model.reminder == nil && model.state.drafts.isEmpty && model.toasts.isEmpty
        guard !isEmpty, height > 1, let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        let height = min(height, visible.height)
        panel.setFrame(NSRect(x: visible.maxX - Self.width - 4, y: visible.maxY - height, width: Self.width, height: height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
