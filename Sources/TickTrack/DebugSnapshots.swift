#if DEBUG
import AppKit
import SwiftUI
import TickTrackCore

/// Отрисовка экранов в PNG без записи экрана: `TICKTRACK_DEMO=1 TICKTRACK_SNAPSHOTS=<папка> …/TickTrack`.
/// Нужна, чтобы проверить вёрстку из терминала. Только в отладочной сборке.
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TICKTRACK_SNAPSHOTS"] else { return false }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task {
            await model.loadInProgress(force: true)
            let found = await model.searchIssues("ATL")
            model.remember(found)
            let ids = ["ATL-1482", "VEG-219", "ORG-3"]

            render(MorningView(model: model, close: {}), "1-morning", folder)
            model.beginDay(plan: ids)
            render(StartWorkView(model: model, close: {}), "2-start", folder)
            render(MenuView(model: model), "3-menu-idle", folder)

            model.startIssue("ATL-1482", at: Date().addingTimeInterval(-42 * 60))
            model.startIssue("VEG-219")
            render(MenuView(model: model), "4-menu-tracking", folder)
            render(CardStackView(model: model), "5-card", folder)
            if let draft = model.state.drafts.first { model.commitDraft(draft, comment: "Анализ: разобрал замечания", type: .analysis) }
            await model.sync()
            model.toast("Не списано", "ORG-3 · 1 мин, это короче 2 мин")
            render(CardStackView(model: model), "6-toasts", folder)
            await model.refreshExternal(force: true)
            render(LogView(model: model, close: {}), "7-log", folder)
            model.mutateState { $0.previousPlan = ["ATL-1482", "ATL-1501"] }
            render(PlanView(model: model, continues: false, close: {}), "8-plan", folder)
            render(ReassignView(model: model, close: {}), "9-reassign", folder)
            render(CreateIssueView(model: model, prefill: "Созвон по бонусам", fromPlan: false, close: {}), "10-create", folder)
            model.idlePrompt = IdlePrompt(start: Date().addingTimeInterval(-20 * 60), end: Date(), issueId: "VEG-219")
            render(IdleReturnView(model: model, prompt: model.idlePrompt!, close: {}), "11-idle", folder)
            render(SettingsView(model: model, close: {}), "12-settings", folder)
            render(AboutView(), "13-about", folder)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func render<V: View>(_ view: V, _ name: String, _ folder: URL) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.padding(12).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(suffix).png"))
        }
    }
}
#endif
