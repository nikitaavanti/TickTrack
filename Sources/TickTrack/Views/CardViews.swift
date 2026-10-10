import SwiftUI
import TickTrackCore

struct CardStackView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let reminder = model.reminder {
                ReminderCard(model: model, reminder: reminder)
            }
            ForEach(model.state.drafts) { draft in
                WriteOffCard(model: model, draft: draft)
            }
            ForEach(model.toasts) { toast in
                ToastView(toast: toast)
            }
        }
        .padding(10)
        .frame(width: CardPanelController.width)
        .animation(.easeOut(duration: 0.2), value: model.toasts)
        .animation(.easeOut(duration: 0.2), value: model.state.drafts)
    }
}

private struct CardBackground: ViewModifier {
    var highlight: Color?

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(width: CardPanelController.width - 20, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .overlay {
                if let highlight {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(highlight, lineWidth: 1.5)
                }
            }
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
        _text = State(initialValue: CommentText.initial(for: draft.suggestedType))
        _remaining = State(initialValue: model.settings.cardSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: draft.issueId)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                Text(verbatim: Fmt.hm(draft.minutes)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text("факт \(Fmt.hm(draft.rawMinutes))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Group {
                    if holding { Text("ждёт вас") } else { Text("спишется через \(remaining) с") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(verbatim: Fmt.short(model.title(of: draft.issueId), 48)).font(.system(size: 12.5)).lineLimit(1)
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
                .onChange(of: fieldFocused) { _, focused in if focused { holding = true } }
                .onChange(of: text) {
                    holding = true
                    model.noteDraftInput(draft, comment: text, type: type)
                }
            HStack {
                Spacer()
                Button("Не списывать") { finish(commit: false) }
                    .buttonStyle(.borderless)
                Button("Списать ↵") { finish(commit: true) }
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.small)
            ProgressView(value: holding ? 0 : Double(remaining), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.linear(duration: 1), value: remaining)
        }
        .modifier(CardBackground())
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Учёт не идёт").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(verbatim: Fmt.clock(model.now)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            message.font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Через 30 мин", action: model.snoozeReminder).buttonStyle(.borderless)
                switch reminder.kind {
                case .dayNotStarted:
                    Button("Начать рабочий день", action: model.openMorning).buttonStyle(.glassProminent)
                case .paused, .untracked:
                    if reminder.issueId != nil {
                        Button("С этой минуты") { model.startFromReminder(backdated: false) }
                        Button("Начать с \(Fmt.clock(reminder.since))") { model.startFromReminder(backdated: true) }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .controlSize(.small)
        }
        .modifier(CardBackground(highlight: .orange))
    }

    private var message: Text {
        switch reminder.kind {
        case .dayNotStarted:
            Text("Вы работаете уже \(reminder.minutes) мин, а рабочий день не начат.")
        case .paused:
            Text("Учёт на паузе уже \(reminder.minutes) мин, а за компьютером идёт работа.")
                + (reminder.issueId.map { Text(" Продолжить \($0)?") } ?? Text(""))
        case .untracked:
            Text("Вы работаете уже \(reminder.minutes) мин без учёта.")
                + (reminder.issueId.map { Text(" Начать \($0)?") } ?? Text(""))
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: toast.title).font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: toast.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .modifier(CardBackground())
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
