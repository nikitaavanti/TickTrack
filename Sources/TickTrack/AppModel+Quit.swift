import AppKit
import Carbon.HIToolbox
import SwiftUI
import TickTrackCore

/// «Завершить TickTrack». Все пути выхода (пункт меню, ⌘Q, кнопка в настройках, система)
/// приходят в `applicationShouldTerminate`, а решение принимает `shouldTerminate()`.
extension AppModel {
    func shouldTerminate() -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }

        // Выход из учётной записи, выключение, перезагрузка: диалог показать нельзя, учёт останавливаем молча.
        if isSystemQuit {
            stopForSystemQuit()
            return .terminateNow
        }

        switch state.status {
        case .notStarted, .ended:
            return .terminateNow
        case .tracking, .paused, .idle:
            // Спрашиваем о том, что важно человеку: закончил ли он работу, — и объясняем, что будет при каждом ответе.
            // Неразрывные пробелы не дают строке оборваться на коротком предлоге.
            let details: LocalizedStringKey = if let segment = state.current {
                "Учёт по\u{00A0}\(segment.issueId) (\(Fmt.hm(elapsedMinutes))) остановится, время уйдёт в\u{00A0}списание. Если ещё вернётесь сегодня — день останется открытым."
            } else {
                "Если да — покажем итог дня и\u{00A0}выйдем. Если ещё вернётесь сегодня — день останется открытым, план и\u{00A0}списания сохранятся."
            }
            // Выход откладываем до ответа: окно-вопрос не модальное. Модальное окно, открытое изнутри
            // нажатия на кнопку SwiftUI («Завершить TickTrack» в меню), не получает нажатий своих кнопок.
            askQuit(details: details)
            return .terminateCancel
        }
    }

    /// Закрывает висящий вопрос при выходе, как «Не выходить».
    func dismissQuitQuestion() {
        if quitWindow != nil { quitChosen(.cancel) }
    }

    private func quitChosen(_ choice: QuitChoice) {
        let window = quitWindow
        quitWindow = nil
        window?.close()
        switch choice {
        case .endDay:
            endDayAndQuit()
        case .comeBack:
            // Как остановка учёта: день остаётся открытым, карточка появится при следующем запуске.
            if state.current != nil { pause() }
            quitConfirmed = true
            NSApp.terminate(nil)
        case .cancel:
            break
        }
    }

    /// Выход из «Итога дня»: висящие карточки списываются как есть, затем пара секунд на отправку.
    /// Не успевшее уйти остаётся в очереди и отправится при следующем запуске.
    func finishQuit() async {
        commitPendingDrafts()
        let deadline = Date().addingTimeInterval(3)
        while state.hasPendingSync, Date() < deadline {
            // Повторный запуск ничего не стоит, если отправка уже идёт, и подхватит записи, созданные во время неё.
            Task { await sync() }
            try? await Task.sleep(for: .milliseconds(200))
        }
        quitConfirmed = true
        NSApp.terminate(nil)
    }

    /// Запоминает, что введено в карточке, чтобы списать это при выходе.
    func noteDraftInput(_ draft: SegmentDraft, comment: String, type: WorkType) {
        draftInputs[draft.id] = DraftInput(comment: comment, type: type)
    }

    private func commitPendingDrafts() {
        for draft in state.drafts {
            let input = draftInputs[draft.id]
            let type = input?.type ?? draft.suggestedType
            commitDraft(draft, comment: input?.comment ?? CommentText.initial(for: type), type: type)
        }
    }

    private func endDayAndQuit() {
        endDay(quitting: true)
    }

    private func stopForSystemQuit() {
        if state.current != nil { pause() }
        save()
    }

    /// Завершение по команде системы, а не пользователя: в событии quit есть причина (logout, restart, shutdown).
    private var isSystemQuit: Bool {
        if systemIsPoweringOff { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    private func askQuit(details: LocalizedStringKey) {
        closeMenu()
        NSApp.activate()
        // Повторный ⌘Q, пока окно открыто, просто поднимает его.
        if let quitWindow {
            quitWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: QuitDialogView(details: details) { [weak self] choice in
            self?.quitChosen(choice)
        })
        let window = NSWindow(contentViewController: controller)
        // Как системное окно предупреждения, но с крестиком: он работает как «Не выходить».
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.quitWindow === window { self?.quitWindow = nil }
            }
        }
        WindowCoordinator.centerOnCursorScreen(window, content: controller.view)
        window.makeKeyAndOrderFront(nil)
        quitWindow = window
    }
}

enum QuitChoice { case endDay, comeBack, cancel }

struct DraftInput {
    var comment: String
    var type: WorkType
}
