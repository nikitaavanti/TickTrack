import AppKit
import SwiftUI
import TickTrackCore

struct CardStackView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.showsLinkCard, let problem = model.link.problem {
                LinkCard(model: model, problem: problem)
            }
            if let reminder = model.reminder {
                ReminderCard(model: model, reminder: reminder)
            }
            ForEach(model.state.drafts) { draft in
                WriteOffCard(model: model, draft: draft)
            }
            ForEach(model.toasts) { toast in
                ToastView(model: model, toast: toast)
            }
        }
        .padding(10)
        .frame(width: CardPanelController.width)
        .animation(.easeOut(duration: 0.2), value: model.toasts)
        .animation(.easeOut(duration: 0.2), value: model.state.drafts)
        .animation(.easeOut(duration: 0.2), value: model.showsLinkCard)
    }
}

/// Карточка в стиле уведомления macOS: иконка приложения слева, стекло, крупное скругление,
/// крестик закрытия в левом верхнем углу при наведении. Кнопки `actions` — под иконкой, на всю ширину карточки.
private struct NotificationCard<Content: View, Actions: View>: View {
    /// Значок поверх иконки приложения: что за уведомление (списано, ошибка, напоминание).
    var badge: (symbol: String, color: Color)?
    var closeHelp: LocalizedStringKey = "Закрыть"
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AppIconBadge(badge: badge)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(width: CardPanelController.width - 20, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(closeHelp)
                .offset(x: -7, y: -7)
                .transition(.opacity)
            }
        }
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
    }
}

extension NotificationCard where Actions == EmptyView {
    init(
        badge: (symbol: String, color: Color)? = nil, closeHelp: LocalizedStringKey = "Закрыть",
        onClose: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.init(badge: badge, closeHelp: closeHelp, onClose: onClose, content: content, actions: { EmptyView() })
    }
}

/// Иконка приложения, как в системных уведомлениях, со значком-пояснением в углу.
private struct AppIconBadge: View {
    let badge: (symbol: String, color: Color)?

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(badge.color))
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                        .offset(x: 4, y: 4)
                }
            }
    }
}

/// Строка заголовка уведомления: жирный заголовок слева, серая подпись справа.
private struct CardHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title.font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            trailing.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Кнопка карточки — капсула, как чипы типов работы. Системные кнопки в неактивирующейся панели
/// рисуются как в неактивном окне: выделенная «Списать» выглядела серой, будто недоступной.
private struct CardButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .monospacedDigit()
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.secondary.opacity(0.15)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Карточка списания: не перехватывает фокус, сама отправляет списание через N секунд, если её не трогать.
struct WriteOffCard: View {
    let model: AppModel
    let draft: SegmentDraft

    @State private var type: WorkType
    @State private var text: String
    @State private var remaining: Int
    @State private var holding = false
    @State private var finished = false
    @FocusState private var fieldFocused: Bool
    private let total: Int

    init(model: AppModel, draft: SegmentDraft) {
        self.model = model
        self.draft = draft
        total = model.settings.cardSeconds
        _type = State(initialValue: draft.suggestedType)
        // Пока в поле не щёлкнули — просто тип, без двоеточия: «Созвон».
        _text = State(initialValue: CommentText.resting(CommentText.initial(for: draft.suggestedType), type: draft.suggestedType))
        _remaining = State(initialValue: model.settings.cardSeconds)
    }

    var body: some View {
        NotificationCard(closeHelp: "Закрыть и списать как есть", onClose: { finish(commit: true) }) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // Справа пусто: отсчёт — на кнопке «Списать».
                    CardHeader(title: Text(verbatim: model.title(of: draft.issueId).isEmpty ? draft.issueId : model.title(of: draft.issueId))) {
                        EmptyView()
                    }
                    .issueContextMenu(model, draft.issueId)
                    HStack(spacing: 0) {
                        IssueIDLink(model: model, id: draft.issueId, font: .system(size: 12).monospacedDigit())
                        Text(verbatim: " · ").foregroundStyle(.secondary)
                        Text("списать \(Fmt.hm(draft.minutes))").fontWeight(.semibold)
                        // Отрезок завершённого задним числом дня — видно, что он не сегодняшний.
                        if let day = Fmt.pastDay(draft.start) {
                            Text(" · за \(day)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                }
                FlowLayout(spacing: 4) {
                    ForEach(WorkType.allCases) { option in
                        ChipButton(title: option.title, selected: option == type) { select(option) }
                    }
                }
                TextField("Комментарий", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { finish(commit: true) }
                    .onExitCommand { finish(commit: false) }
                    .onChange(of: fieldFocused) { _, focused in
                        if focused { holding = true }
                        // Щёлкнули в поле — «Созвон: », можно дописывать; ушли, ничего не дописав, — снова «Созвон».
                        text = focused ? CommentText.editing(text, type: type) : CommentText.resting(text, type: type)
                    }
                    .onChange(of: text) {
                        holding = true
                        model.noteDraftInput(draft, comment: text, type: type)
                    }
                HStack(spacing: 8) {
                    // Тонкая полоса отсчёта, как индикатор в системных уведомлениях; пока ждём пользователя — скрыта.
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(Color.accentColor)
                                    .frame(width: proxy.size.width * (holding ? 0 : Double(remaining) / Double(max(total, 1))))
                                    .animation(.linear(duration: 1), value: remaining)
                            }
                        }
                        .opacity(holding ? 0 : 1)
                    Button("Не списывать") { finish(commit: false) }
                        .buttonStyle(CardButtonStyle())
                    // Пока идёт отсчёт, кнопка говорит, что нажмётся сама: «Списать через 3 с».
                    // Enter списывает только из поля комментария: панель неактивирующая, без фокуса клавиши не доходят.
                    Button { finish(commit: true) } label: {
                        if holding {
                            HStack(spacing: 4) {
                                Text("Списать")
                                if fieldFocused { Text(verbatim: "↩").opacity(0.7) }
                            }
                        } else {
                            // Ширина — по самой длинной надписи, чтобы кнопка не дёргалась, когда секунд становится меньше 10.
                            ZStack {
                                Text("Списать через \(total) с").hidden()
                                Text("Списать через \(remaining) с")
                            }
                        }
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                }
            }
        }
        .task {
            while !Task.isCancelled, !holding, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !holding, !Task.isCancelled else { return }
                remaining -= 1
            }
            if !holding, remaining <= 0 { finish(commit: true) }
        }
    }

    private func select(_ option: WorkType) {
        type = option
        text = CommentText.replacingType(in: text, with: option)
        if !fieldFocused { text = CommentText.resting(text, type: option) }
        holding = true
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit {
            model.commitDraft(draft, comment: text, type: type)
        } else {
            model.discardDraft(draft)
        }
    }
}

/// Напоминание о забытом старте: в той же стопке, с выделенной рамкой.
struct ReminderCard: View {
    let model: AppModel
    let reminder: Reminder

    var body: some View {
        NotificationCard(badge: ("clock", .orange), closeHelp: "Напомнить через 10 мин", onClose: model.snoozeReminder) {
            VStack(alignment: .leading, spacing: 2) {
                CardHeader(title: Text("Учёт не идёт")) { Text(verbatim: Fmt.clock(model.now)) }
                message.font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            // Подписи длинные: в один ряд три кнопки не помещаются, поэтому «Напомнить» — отдельным рядом.
            // Учёт остановлен, а человек за компьютером — возможно, рабочий день уже кончился: рядом «Завершить день».
            VStack(spacing: 4) {
                switch reminder.kind {
                case .dayNotStarted:
                    Button { model.startDay() } label: { Text("Начать рабочий день").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                case .paused, .untracked:
                    if reminder.issueId != nil {
                        HStack(spacing: 4) {
                            Button { model.startFromReminder(backdated: false) } label: {
                                Text("Начать учёт сейчас").frame(maxWidth: .infinity)
                            }
                            Button { model.startFromReminder(backdated: true) } label: {
                                Text("Учёт с \(Fmt.clock(reminder.since))").frame(maxWidth: .infinity)
                            }
                            .help("Начать учёт задним числом, с \(Fmt.clock(reminder.since)), когда он остановился")
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
                if reminder.kind == .dayNotStarted {
                    Button(action: model.snoozeReminder) { Text("Напомнить через 10 минут").frame(maxWidth: .infinity) }
                } else {
                    HStack(spacing: 4) {
                        Button { model.endDay() } label: { Text("Завершить день").frame(maxWidth: .infinity) }
                        Button(action: model.snoozeReminder) { Text("Напомнить через 10 мин").frame(maxWidth: .infinity) }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var message: Text {
        switch reminder.kind {
        case .dayNotStarted:
            Text("Вы работаете уже \(reminder.minutes) мин, а рабочий день не начат.")
        case .paused:
            Text("Учёт остановлен уже \(reminder.minutes) мин, а за компьютером идёт работа.")
                + (reminder.issueId.map { Text(" Продолжить \($0)?") } ?? Text(""))
        case .untracked:
            Text("Вы работаете уже \(reminder.minutes) мин без учёта.")
                + (reminder.issueId.map { Text(" Начать \($0)?") } ?? Text(""))
        }
    }
}

/// Нет связи с YouTrack, а в очереди есть списания: они сохранены и уйдут сами. Карточка не пропадает сама —
/// её убирает восстановление связи или «Скрыть».
struct LinkCard: View {
    let model: AppModel
    let problem: LinkProblem

    var body: some View {
        NotificationCard(badge: badge, closeHelp: "Скрыть", onClose: model.hideLinkCard) {
            VStack(alignment: .leading, spacing: 2) {
                CardHeader(title: problem == .tokenRejected ? Text("YouTrack не принял токен") : Text("Нет связи с YouTrack")) {
                    if let since = model.link.failingSince { Text("с \(Fmt.clock(since))") }
                }
                message.font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            HStack(spacing: 4) {
                Button(action: model.hideLinkCard) { Text("Скрыть").frame(maxWidth: .infinity) }
                if problem == .tokenRejected {
                    Button { model.openSettings() } label: { Text("Открыть настройки").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                } else {
                    Button(action: model.retryLink) {
                        Text(model.linkRetrying ? "Проверяем…" : "Повторить сейчас").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.linkRetrying)
                }
            }
            .controlSize(.small)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var badge: (symbol: String, color: Color) {
        switch problem {
        case .noNetwork: ("wifi.slash", .red)
        case .notResponding: ("exclamationmark", .red)
        case .tokenRejected: ("key.fill", .red)
        }
    }

    private var message: Text {
        let reason: Text = switch problem {
        case .noNetwork: Text("Mac не подключён к сети.")
        case .notResponding: Text("YouTrack не отвечает.")
        case .tokenRejected: Text("Укажите новый токен в настройках.")
        }
        let when = problem == .tokenRejected ? "как только YouTrack примет новый токен" : "когда связь появится"
        guard let pending = model.pendingSummary else {
            return reason + Text(" Учёт работает как обычно, изменения сохранены и уйдут в YouTrack, \(when).")
        }
        return reason + Text(" Учёт работает как обычно: \(pending.phrase) (\(Fmt.hm(pending.minutes))) \(pending.verb("сохранено и уйдёт", "сохранены и уйдут")) в YouTrack, \(when).")
    }
}

struct ToastView: View {
    let model: AppModel
    let toast: Toast

    var body: some View {
        NotificationCard(
            badge: toast.isError ? ("exclamationmark", .orange) : ("checkmark", .green),
            onClose: { model.dismissToast(toast) }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                CardHeader(title: Text(verbatim: toast.title)) { Text("сейчас") }
                Text(verbatim: toast.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
