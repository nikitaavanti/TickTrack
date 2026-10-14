import AppKit
import SwiftUI
import TickTrackCore

/// Обычные окна приложения (настройки, «План на день» и т. д.). Окна независимы друг от друга.
///
/// Окно ставится посередине экрана, на котором курсор, уже с итоговым размером. Когда содержимое
/// меняет высоту, верхний край окна остаётся на месте, а само окно не уходит за край экрана.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]
    /// Верхний край и размер окна на момент последней расстановки: по ним отличаем перетаскивание от изменения размера.
    private var anchors: [String: (top: CGFloat, size: NSSize)] = [:]

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
        }
        window.title = title
        closeHandlers[id] = onClose
        if !window.isVisible { place(window, id: id, content: controller.view) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    /// Задаёт окну итоговый размер содержимого и ставит его посередине экрана с курсором.
    private func place(_ window: NSWindow, id: String, content: NSView) {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if size.width > 0, size.height > 0 { window.setContentSize(size) }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(fit(frame, in: visible), display: false)
        anchors[id] = (window.frame.maxY, window.frame.size)
    }

    /// Сдвигает рамку так, чтобы она помещалась в видимую область экрана; верх важнее низа.
    private func fit(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = max(frame.minY, visible.minY)
        frame.origin.y = min(frame.minY, visible.maxY - frame.height)
        return frame
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue,
              let anchor = anchors[id], window.frame.size != anchor.size else { return }
        var frame = window.frame
        frame.origin.y = anchor.top - frame.height
        if let visible = window.screen?.visibleFrame { frame = fit(frame, in: visible) }
        anchors[id] = (frame.maxY, frame.size)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// Окно перетащили: новый верхний край становится опорным.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue,
              anchors[id]?.size == window.frame.size else { return }
        anchors[id] = (window.frame.maxY, window.frame.size)
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
        anchors.removeValue(forKey: id)
        closeHandlers.removeValue(forKey: id)?()
    }
}

/// Открытие окон из модели.
extension AppModel {
    private func closer(_ id: String) -> () -> Void {
        { [weak self] in self?.windows.close(id) }
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

    /// `then` вызывается после закрытия окна плана: так «Начать рабочий день» и «Дополнить план…» ведут дальше.
    func openPlan(then next: (() -> Void)? = nil) {
        closeMenu()
        Task { await refreshIssues(state.plan + state.previousPlanSuggestions) }
        windows.show("plan", title: "План на день", onClose: next) {
            PlanView(model: self, continues: next != nil, close: closer("plan"))
        }
    }

    /// `quitting` — «Итог дня» перед выходом: вместо «Закрыть» кнопка «Выйти».
    func openLog(title: String = "Списания за сегодня", quitting: Bool = false) {
        closeMenu()
        Task { await refreshExternal(force: true) }
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

    /// `then` вызывается после закрытия настроек: при первом запуске следом открывается «План на день».
    func openSettings(then next: (() -> Void)? = nil) {
        closeMenu()
        windows.show("settings", title: "Настройки", onClose: next) {
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
    static let width: CGFloat = 390

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
