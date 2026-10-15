import AppKit
import SwiftUI

/// Значок в строке меню и выпадающее меню.
///
/// Меню — своя неактивирующаяся панель, а не `MenuBarExtra`: так глобальное сочетание может открывать
/// и закрывать меню, у значка есть цветной индикатор и подсказка, а клавиши работают поверх любого приложения.
final class MenuBarController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = FloatingPanel(level: .popUpMenu)
    private var lastClosed = Date.distantPast
    private var contentHeight: CGFloat = 300
    private let layout = MenuLayout()
    static let width: CGFloat = 360
    static let cornerRadius: CGFloat = 14

    init(model: AppModel) {
        self.model = model
        super.init()
        panel.delegate = self
        panel.hasShadow = true
        let host = NSHostingView(rootView: HeightReporting(onHeight: { [weak self] in self?.setHeight($0) }) {
            MenuRoot(model: model, layout: layout)
        })
        host.sizingOptions = []
        // Обрезаем панель по скруглению стекла: тень окна строится по непрозрачным пикселям,
        // и без обрезки у неё остаются квадратные углы.
        host.wantsLayer = true
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.imagePosition = .imageLeading
        }
        refreshStatusItem()
        observeStatus()
    }

    var isOpen: Bool { panel.isVisible }

    @objc private func statusItemClicked() {
        toggle()
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            // Клик по значку при открытом меню сначала закрывает его через потерю фокуса — не открываем заново.
            open()
        }
    }

    func open() {
        model.menuSession += 1
        Task { [model] in await model.refreshExternal() }
        Task { [model] in await model.refreshPlanIssuesIfStale() }
        layout.maxHeight = availableHeight()
        panel.setFrame(frame(height: contentHeight), display: true)
        panel.makeKeyAndOrderFront(nil)
        refreshShadow()
        statusItem.button?.highlight(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        statusItem.button?.highlight(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// После программной установки фокуса поле выделяет весь текст — ставим курсор в конец.
    func moveCaretToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.panel.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func setHeight(_ height: CGFloat) {
        contentHeight = height
        guard panel.isVisible else { return }
        panel.setFrame(frame(height: height), display: true)
        refreshShadow()
    }

    /// Тень окна строится по его содержимому. Пересчитываем её и после перерисовки: иначе остаётся тень
    /// от промежуточного вида (например, меню, обрезанного снизу экраном) — с квадратными углами.
    private func refreshShadow() {
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    /// Кнопка значка в координатах экрана и сам экран.
    private var anchor: (button: NSRect, visible: NSRect)? {
        guard let button = statusItem.button, let window = button.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen.visibleFrame)
    }

    /// Сколько места есть от значка до низа экрана.
    private func availableHeight() -> CGFloat {
        guard let anchor else { return (NSScreen.main?.visibleFrame.height ?? 800) - 8 }
        return anchor.button.minY - 4 - anchor.visible.minY - 8
    }

    private func frame(height: CGFloat) -> NSRect {
        let width = Self.width
        let height = min(height, availableHeight())
        guard let anchor else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: visible.maxX - width - 8, y: visible.maxY - height, width: width, height: height)
        }
        let x = min(max(anchor.button.minX, anchor.visible.minX + 8), anchor.visible.maxX - width - 8)
        return NSRect(x: x, y: anchor.button.minY - 4 - height, width: width, height: height)
    }

    // MARK: - Значок

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: model.indicator, linkDown: model.link.problem != nil)
        button.title = model.menuBarTitle.map { " " + $0 } ?? ""
        button.toolTip = model.statusToolTip
    }

    private func observeStatus() {
        withObservationTracking {
            _ = model.menuBarTitle
            _ = model.statusToolTip
            _ = model.indicator
            _ = model.link.problem
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStatusItem()
                self?.observeStatus()
            }
        }
    }
}

/// Кот из `Support/MenuBar` (в ресурсах приложения): спит — учёт не идёт, щурится — учёт остановлен посреди дня, смотрит — учёт идёт.
/// Рядом цветная точка: зелёная — учёт идёт, жёлтая — учёт остановлен. Когда учёт не идёт (день не начат или задача не выбрана), точки нет.
/// Нет связи с YouTrack — точка красная при любом коте: учёт без связи продолжается, поэтому кот по-прежнему показывает учёт. Без ресурсов (`swift run`) вместо кота часы.
enum StatusIcon {
    private static let cats: [Indicator: NSImage] = {
        let names: [Indicator: String] = [.idle: "CatSleeping", .paused: "CatPaused", .running: "CatActive"]
        // `image(forResource:)` сам подхватывает @2x рядом с файлом.
        return names.compactMapValues { Bundle.main.image(forResource: $0) }
    }()

    static func image(for indicator: Indicator, linkDown: Bool = false) -> NSImage {
        let dotColor: NSColor? = if linkDown { .systemRed } else {
            switch indicator {
            case .running: .systemGreen
            case .paused: .systemYellow
            case .idle: nil
            }
        }
        let cat = cats[indicator]
        // Кот 28×22, точка — в его пустом правом нижнем углу, под «Z» спящего кота.
        let size = cat == nil ? NSSize(width: 21, height: 16) : NSSize(width: 28, height: 22)
        let dot = cat == nil ? NSRect(x: 15, y: 1, width: 6, height: 6) : NSRect(x: 22, y: 0, width: 5, height: 5)
        // Рисуем при каждом отображении: цвет кота или часов берётся из текущего оформления строки меню.
        let image = NSImage(size: size, flipped: false) { rect in
            if let cat {
                cat.draw(in: rect)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceAtop)
            } else {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    .applying(.init(paletteColors: [.labelColor]))
                if let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let clockSize = clock.size
                    clock.draw(in: NSRect(x: 0, y: (size.height - clockSize.height) / 2, width: clockSize.width, height: clockSize.height))
                }
            }
            if let dotColor {
                dotColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "TickTrack"
        return image
    }
}

/// Сколько места есть под меню на экране. Меню по нему ограничивает высоту списка задач.
@Observable final class MenuLayout {
    var maxHeight: CGFloat = .infinity
}

private struct MenuMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    /// Наибольшая высота меню; `.infinity`, если экран не ограничивает (например, при отрисовке в PNG).
    var menuMaxHeight: CGFloat {
        get { self[MenuMaxHeightKey.self] }
        set { self[MenuMaxHeightKey.self] = newValue }
    }
}
