import Foundation

public struct YouTrackUser: Codable, Sendable, Equatable {
    public var id: String
    public var login: String
    public var fullName: String?

    public init(id: String, login: String, fullName: String?) {
        self.id = id
        self.login = login
        self.fullName = fullName
    }
}

public enum YouTrackError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int, message: String)
    case network(String)
    case decoding(String)

    /// Нет связи: запись остаётся в очереди и уйдёт позже.
    public var isConnectivity: Bool {
        if case .network = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Не указан адрес YouTrack или токен. Откройте настройки."
        case .unauthorized: "YouTrack не принял токен. Проверьте его в настройках."
        case .forbidden: "Недостаточно прав в YouTrack для этого действия."
        case .notFound: "Не найдено в YouTrack."
        case .server(let status, let message): message.isEmpty ? "YouTrack ответил ошибкой \(status)." : "YouTrack: \(message)"
        case .network(let message): "Нет связи с YouTrack: \(message)"
        case .decoding: "Не удалось разобрать ответ YouTrack."
        }
    }
}

public protocol YouTrackAPI: Sendable {
    func currentUser() async throws -> YouTrackUser
    func searchIssues(query: String, top: Int) async throws -> [Issue]
    func projects() async throws -> [Project]
    func createIssue(projectId: String, summary: String, description: String) async throws -> Issue
    func assignToMe(issueId: String) async throws
    func createWorkItem(issueId: String, minutes: Int, text: String, date: Int64) async throws -> String
    func updateWorkItem(issueId: String, workItemId: String, minutes: Int, text: String, date: Int64) async throws
    func deleteWorkItem(issueId: String, workItemId: String) async throws
    /// Списания автора за день `day` (`YYYY-MM-DD`) и задачи, к которым они относятся.
    func workItems(authorId: String, day: String) async throws -> (items: [ExternalWorkItem], issues: [Issue])
}

/// REST-клиент YouTrack с постоянным токеном.
public struct YouTrackClient: YouTrackAPI {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    private static let issueFields = "id,idReadable,summary,project(id,name,shortName)"

    /// `nil`, если адрес или токен пустые.
    public init?(server: String, token: String, session: URLSession = .shared) {
        var address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !token.isEmpty else { return nil }
        if !address.contains("://") { address = "https://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        guard let url = URL(string: address), url.host() != nil else { return nil }
        self.baseURL = url
        self.token = token
        self.session = session
    }

    public func currentUser() async throws -> YouTrackUser {
        try await get("api/users/me", ["fields": "id,login,fullName"])
    }

    public func searchIssues(query: String, top: Int) async throws -> [Issue] {
        let list: [IssueDTO] = try await get("api/issues", ["query": query, "fields": Self.issueFields, "$top": String(top)])
        return list.map(\.issue)
    }

    public func projects() async throws -> [Project] {
        let list: [ProjectDTO] = try await get("api/admin/projects", ["fields": "id,name,shortName", "$top": "500"])
        return list.map(\.project)
    }

    public func createIssue(projectId: String, summary: String, description: String) async throws -> Issue {
        var body: [String: Any] = ["project": ["id": projectId], "summary": summary]
        if !description.isEmpty { body["description"] = description }
        let data = try await send("POST", "api/issues", ["fields": Self.issueFields], body: body)
        return try decode(IssueDTO.self, data).issue
    }

    public func assignToMe(issueId: String) async throws {
        _ = try await send("POST", "api/commands", [:], body: ["query": "for me", "issues": [["idReadable": issueId]]])
    }

    public func createWorkItem(issueId: String, minutes: Int, text: String, date: Int64) async throws -> String {
        let data = try await send(
            "POST", "api/issues/\(issueId)/timeTracking/workItems", ["fields": "id"],
            body: workItemBody(minutes: minutes, text: text, date: date)
        )
        return try decode(IdDTO.self, data).id
    }

    public func updateWorkItem(issueId: String, workItemId: String, minutes: Int, text: String, date: Int64) async throws {
        _ = try await send(
            "POST", "api/issues/\(issueId)/timeTracking/workItems/\(workItemId)", ["fields": "id"],
            body: workItemBody(minutes: minutes, text: text, date: date)
        )
    }

    public func deleteWorkItem(issueId: String, workItemId: String) async throws {
        _ = try await send("DELETE", "api/issues/\(issueId)/timeTracking/workItems/\(workItemId)", [:], body: nil)
    }

    public func workItems(authorId: String, day: String) async throws -> (items: [ExternalWorkItem], issues: [Issue]) {
        let list: [WorkItemDTO] = try await get("api/workItems", [
            "author": authorId, "startDate": day, "endDate": day, "$top": "500",
            "fields": "id,date,created,text,duration(minutes),issue(\(Self.issueFields))",
        ])
        let items = list.compactMap { dto -> ExternalWorkItem? in
            guard let issue = dto.issue, let date = dto.date else { return nil }
            return ExternalWorkItem(
                id: dto.id, issueId: issue.idReadable, minutes: dto.duration?.minutes ?? 0, text: dto.text ?? "",
                date: date, created: dto.created.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
        }
        return (items, list.compactMap { $0.issue?.issue })
    }

    // MARK: - Транспорт

    private func workItemBody(minutes: Int, text: String, date: Int64) -> [String: Any] {
        ["duration": ["minutes": minutes], "text": text, "date": date]
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        try decode(T.self, try await send("GET", path, query, body: nil))
    }

    private func send(_ method: String, _ path: String, _ query: [String: String], body: [String: Any]?) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents не кодирует «+», а сервер читает его как пробел.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw YouTrackError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw YouTrackError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw YouTrackError.network("нет ответа") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw YouTrackError.unauthorized
        case 403: throw YouTrackError.forbidden
        case 404: throw YouTrackError.notFound
        default: throw YouTrackError.server(status: http.statusCode, message: Self.errorMessage(in: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YouTrackError.decoding(String(describing: error))
        }
    }

    private static func errorMessage(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (json["error_description"] as? String) ?? (json["error"] as? String) ?? ""
    }
}

private struct IdDTO: Decodable {
    let id: String
}

private struct ProjectDTO: Decodable {
    let id: String
    let name: String?
    let shortName: String?

    var project: Project {
        Project(id: id, name: name ?? shortName ?? id, shortName: shortName ?? "")
    }
}

private struct WorkItemDTO: Decodable {
    struct Duration: Decodable { let minutes: Int? }
    let id: String
    let date: Int64?
    let created: Int64?
    let text: String?
    let duration: Duration?
    let issue: IssueDTO?
}

private struct IssueDTO: Decodable {
    let idReadable: String
    let summary: String?
    let project: ProjectDTO?

    var issue: Issue {
        Issue(idReadable: idReadable, summary: summary ?? "", project: project?.project)
    }
}
