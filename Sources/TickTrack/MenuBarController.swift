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
    static let width: CGFloat = 360

    init(model: AppModel) {
        self.model = model
        super.init()
        panel.delegate = self
        panel.hasShadow = true
        let host = NSHostingView(rootView: HeightReporting(onHeight: { [weak self] in self?.setHeight($0) }) {
            MenuRoot(model: model)
        })
        host.sizingOptions = []
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
        panel.setFrame(frame(height: contentHeight), display: true)
        panel.makeKeyAndOrderFront(nil)
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
        panel.invalidateShadow()
    }

    private func frame(height: CGFloat) -> NSRect {
        let width = Self.width
        guard let button = statusItem.button, let window = button.window, let screen = window.screen ?? NSScreen.main else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: visible.maxX - width - 8, y: visible.maxY - height, width: width, height: height)
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(buttonFrame.minX, visible.minX + 8), visible.maxX - width - 8)
        let height = min(height, visible.height - 8)
        return NSRect(x: x, y: buttonFrame.minY - 4 - height, width: width, height: height)
    }

    // MARK: - Значок

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: model.indicator)
        button.title = " " + model.menuBarTitle
        button.toolTip = model.statusToolTip
    }

    private func observeStatus() {
        withObservationTracking {
            _ = model.menuBarTitle
            _ = model.statusToolTip
            _ = model.indicator
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStatusItem()
                self?.observeStatus()
            }
        }
    }
}

/// Часы и цветная точка состояния: зелёная — учёт идёт, жёлтая — пауза, серая — не идёт.
enum StatusIcon {
    static func image(for indicator: Indicator) -> NSImage {
        let dotColor: NSColor = switch indicator {
        case .running: .systemGreen
        case .paused: .systemYellow
        case .idle: .systemGray
        }
        let size = NSSize(width: 21, height: 16)
        // Рисуем при каждом отображении: цвет часов берётся из текущего оформления строки меню.
        let image = NSImage(size: size, flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [.labelColor]))
            if let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let clockSize = clock.size
                clock.draw(in: NSRect(x: 0, y: (size.height - clockSize.height) / 2, width: clockSize.width, height: clockSize.height))
            }
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 1, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "TickTrack"
        return image
    }
}
