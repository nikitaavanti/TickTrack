#if DEBUG
import Foundation
import TickTrackCore

/// Мок YouTrack для разработки без сервера: `TICKTRACK_DEMO=1 swift run`.
/// Только в отладочной сборке — в релиз тестовые данные не попадают.
actor DemoYouTrack: YouTrackAPI {
    private var issues: [Issue]
    private var workItems: [String: (issueId: String, minutes: Int, text: String, date: Int64)] = [:]
    private let projectList: [Project]

    init() {
        let projects = [
            Project(id: "0-1", name: "Atlas", shortName: "ATL"),
            Project(id: "0-2", name: "Vega", shortName: "VEG"),
            Project(id: "0-3", name: "Лира", shortName: "LYR"),
            Project(id: "0-4", name: "Общее", shortName: "ORG"),
        ]
        projectList = projects
        func issue(_ id: String, _ summary: String, _ project: Int) -> Issue {
            Issue(idReadable: id, summary: summary, project: projects[project])
        }
        issues = [
            issue("ATL-1482", "Экспорт отчёта в Excel", 0),
            issue("ATL-1490", "Черновики в редакторе профиля", 0),
            issue("ATL-1501", "Каталог: согласование изменений", 0),
            issue("ATL-1520", "Журнал событий: новые фильтры", 0),
            issue("VEG-214", "Vega: замечания после запуска", 1),
            issue("VEG-219", "Vega: спецификация программы лояльности", 1),
            issue("LYR-902", "Платформа Лира: права доступа к черновикам", 2),
            issue("ORG-3", "Встречи и внутренние созвоны", 3),
            issue("ORG-7", "Планирование спринта", 3),
        ]
        // Списание, сделанное «прямо в YouTrack», чтобы было видно, как такие записи показываются.
        let today = TimeMath.youTrackDate(for: Date(), calendar: .current)
        workItems["demo-external"] = ("ORG-7", 30, "Созвон: планирование спринта", today)
    }

    func currentUser() async throws -> YouTrackUser {
        YouTrackUser(id: "1-1", login: "demo", fullName: "Демо-пользователь")
    }

    func searchIssues(query: String, top: Int) async throws -> [Issue] {
        try await Task.sleep(for: .milliseconds(150))
        if query.hasPrefix("for: me") {
            return issues.filter { ["ATL-1501", "ATL-1520", "VEG-214"].contains($0.idReadable) }
        }
        let q = query.lowercased()
        return Array(issues.filter { $0.idReadable.lowercased().contains(q) || $0.summary.lowercased().contains(q) }.prefix(top))
    }

    func issue(id: String) async throws -> Issue {
        try await Task.sleep(for: .milliseconds(100))
        guard let issue = issues.first(where: { $0.idReadable == id }) else { throw YouTrackError.notFound }
        return issue
    }

    func projects() async throws -> [Project] { projectList }

    func createIssue(projectId: String, summary: String, description: String) async throws -> Issue {
        let project = projectList.first { $0.id == projectId } ?? projectList[0]
        let numbers = issues.filter { $0.project?.id == project.id }.compactMap { Int($0.idReadable.split(separator: "-").last ?? "") }
        let issue = Issue(idReadable: "\(project.shortName)-\((numbers.max() ?? 0) + 1)", summary: summary, project: project)
        issues.append(issue)
        return issue
    }

    func assignToMe(issueId: String) async throws {}

    func createWorkItem(issueId: String, minutes: Int, text: String, date: Int64) async throws -> String {
        let id = UUID().uuidString
        workItems[id] = (issueId, minutes, text, date)
        return id
    }

    func updateWorkItem(issueId: String, workItemId: String, minutes: Int, text: String, date: Int64) async throws {
        guard workItems[workItemId] != nil else { throw YouTrackError.notFound }
        workItems[workItemId] = (issueId, minutes, text, date)
    }

    func deleteWorkItem(issueId: String, workItemId: String) async throws {
        workItems.removeValue(forKey: workItemId)
    }

    func workItems(authorId: String, day: String) async throws -> (items: [ExternalWorkItem], issues: [Issue]) {
        let items = workItems.map { id, item in
            ExternalWorkItem(id: id, issueId: item.issueId, minutes: item.minutes, text: item.text, date: item.date, created: nil)
        }
        return (items, issues.filter { issue in items.contains { $0.issueId == issue.idReadable } })
    }
}
#endif
