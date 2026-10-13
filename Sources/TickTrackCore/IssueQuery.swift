import Foundation

/// Запросы к YouTrack с учётом «Моих проектов» из настроек.
public enum IssueQuery {
    /// Полный ID задачи вида `VEG-4499`: такую задачу ищем во всех проектах — пользователь точно знает, что ищет.
    public static func isIssueId(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*-[0-9]+/) != nil
    }

    /// Фильтр по проектам: `project: {ATLAS}, {VEG}`. Пустой, если проекты не выбраны.
    public static func projectFilter(_ projects: [String]) -> String {
        let names = projects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        return "project: " + names.map { "{\($0)}" }.joined(separator: ", ")
    }

    /// Поиск из поля «ID или текст». Ограничивается своими проектами, кроме поиска по точному ID.
    public static func search(_ text: String, projects: [String]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = projectFilter(projects)
        guard !filter.isEmpty, !isIssueId(text) else { return text }
        return text.isEmpty ? filter : "\(filter) \(text)"
    }

    /// Запрос из настроек (например, «в работе у меня»), ограниченный своими проектами.
    /// Если в запросе есть `or`, он берётся в скобки, чтобы фильтр относился ко всему запросу.
    public static func restricted(_ query: String, projects: [String]) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = projectFilter(projects)
        guard !filter.isEmpty else { return query }
        guard !query.isEmpty else { return filter }
        if query.range(of: #"\bor\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "(\(query)) and \(filter)"
        }
        return "\(query) \(filter)"
    }

    /// Задача из своих проектов (или проекты не выбраны). Задачи без известного проекта не отсеиваем.
    public static func isInProjects(_ issue: Issue, _ projects: [String]) -> Bool {
        guard !projects.isEmpty, let shortName = issue.project?.shortName, !shortName.isEmpty else { return true }
        return projects.contains { $0.caseInsensitiveCompare(shortName) == .orderedSame }
    }
}
