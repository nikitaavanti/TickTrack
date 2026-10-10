import AppKit
import Carbon.HIToolbox
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
        case .tracking(let segment):
            let choice = askQuit(
                message: "Идёт учёт по \(segment.issueId) · \(Fmt.hm(elapsedMinutes))",
                details: "Учёт остановится. Завершить рабочий день?",
                alternative: "Только остановить и выйти"
            )
            switch choice {
            case .endDay:
                endDayAndQuit()
                return .terminateCancel
            case .alternative:
                // Как пауза: день остаётся открытым, карточка появится при следующем запуске.
                pause()
                return .terminateNow
            case .cancel:
                return .terminateCancel
            }
        case .paused, .idle:
            let choice = askQuit(message: "Завершить рабочий день?", details: nil, alternative: "Просто выйти")
            switch choice {
            case .endDay:
                endDayAndQuit()
                return .terminateCancel
            case .alternative:
                return .terminateNow
            case .cancel:
                return .terminateCancel
            }
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

    private enum QuitChoice { case endDay, alternative, cancel }

    private func askQuit(message: String, details: String?, alternative: String) -> QuitChoice {
        closeMenu()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        if let details { alert.informativeText = details }
        alert.addButton(withTitle: "Завершить день и выйти")
        alert.addButton(withTitle: alternative)
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .endDay
        case .alertSecondButtonReturn: return .alternative
        default: return .cancel
        }
    }
}

struct DraftInput {
    var comment: String
    var type: WorkType
}
