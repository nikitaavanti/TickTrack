import SwiftUI
import TickTrackCore

/// Строка в стиле пункта меню macOS: подсветка при наведении.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor : .clear))
                .onHover { hovering = $0 }
        }
    }
}

struct MenuRow: View {
    /// Иконка команды (SF Symbol). У задач вместо неё `mark` — галочка текущей.
    var icon: String?
    var mark: String = ""
    var title: Text
    /// `ID · проект` у задач — моноширинным шрифтом.
    var subtitle: String?
    /// Пояснение к команде — обычным шрифтом.
    var hint: LocalizedStringKey?
    var trailing: String?
    var shortcut: String?
    var bold = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(tint ?? .primary)
                    } else {
                        Text(mark).font(.system(size: 12))
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    title.fontWeight(bold ? .semibold : .regular).foregroundStyle(tint ?? .primary).lineLimit(1)
                    if let subtitle {
                        Text(verbatim: subtitle).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let hint {
                        Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(verbatim: trailing).font(.system(size: 11.5, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(verbatim: shortcut ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            }
        }
        .buttonStyle(MenuRowStyle())
    }
}

struct SectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
    }
}

struct StatusDot: View {
    let indicator: Indicator

    var body: some View {
        Circle()
            .fill(indicator == .running ? Color.green : indicator == .paused ? Color.yellow : Color.gray)
            .frame(width: 7, height: 7)
    }
}

/// Раскладка «в строку с переносом» для кнопок типов работы и подсказок.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// Кнопка-«чип»: тип работы, подсказка `+ ID`.
struct ChipButton: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// Результаты поиска по YouTrack с задержкой 250 мс. Пустой запрос ничего не показывает.
struct IssueSearchResults: View {
    let model: AppModel
    let query: String
    @Binding var results: [Issue]
    var limit = 8
    let onPick: (Issue) -> Void
    var onCreate: ((String) -> Void)?

    @State private var loading = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading && results.isEmpty {
                ProgressView().controlSize(.small).padding(6)
            } else if results.isEmpty {
                Text("В YouTrack ничего не найдено. Проверьте ID или формулировку.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                ForEach(results.prefix(limit)) { issue in
                    MenuRow(
                        mark: model.state.plan.contains(issue.idReadable) ? "•" : "",
                        title: Text(verbatim: issue.summary),
                        subtitle: issue.idReadable + " · " + issue.projectName + (model.isInProgress(issue.idReadable) ? " · в работе у вас" : "")
                    ) { onPick(issue) }
                }
            }
            if let onCreate, !trimmed.isEmpty {
                MenuRow(icon: "plus", title: Text("Создать «\(Fmt.short(trimmed, 30))» в YouTrack"), tint: .accentColor) {
                    onCreate(trimmed)
                }
            }
        }
        .task(id: trimmed) {
            guard !trimmed.isEmpty else {
                results = []
                loading = false
                return
            }
            loading = true
            defer { loading = false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchIssues(trimmed)
            guard !Task.isCancelled else { return }
            results = found
        }
    }
}

/// Выбор задачи из плана и известных задач.
struct IssuePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    let issues: [Issue]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(issues) { issue in
                Text(verbatim: issue.idReadable + (issue.summary.isEmpty ? "" : " — " + Fmt.short(issue.summary, 44)))
                    .tag(issue.idReadable)
            }
        }
    }
}

/// Строка задачи в списках окон.
struct IssueLine: View {
    let id: String
    let title: String
    /// Задачи нет в YouTrack или к ней нет доступа: вместо названия — пояснение.
    var unavailable = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            if unavailable {
                Text("нет доступа в YouTrack").foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// Рамка-список, как в системных настройках.
struct BoxedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// «84 % нормы · ещё 1:15» или, с `showingNorm`, «84 % от нормы 8 ч · ещё 1:15».
/// Когда норма набрана, остаток не показывается: «110 % нормы».
@MainActor
func normText(_ model: AppModel, showingNorm: Bool = false) -> Text {
    let percent = showingNorm
        ? Text("\(model.normPercentToday)\u{00A0}% от нормы \(model.settings.dailyNorm.hoursText)\u{00A0}ч")
        : Text("\(model.normPercentToday)\u{00A0}% нормы")
    guard model.normRemainingToday > 0 else { return percent }
    return percent + Text(" · ещё ") + Text(verbatim: Fmt.hm(model.normRemainingToday))
}
