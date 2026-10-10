import Foundation

/// Тип работы. В YouTrack это не отдельное поле, а приставка комментария: `Анализ: разобрал замечания`.
public enum WorkType: String, CaseIterable, Codable, Sendable, Identifiable {
    case development = "Разработка"
    case analysis = "Анализ"
    case call = "Созвон"
    case testing = "Тестирование"
    case documentation = "Документация"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    /// Внутренний id YouTrack (`0-12`), нужен для создания задачи.
    public var id: String
    public var name: String
    public var shortName: String

    public init(id: String, name: String, shortName: String) {
        self.id = id
        self.name = name
        self.shortName = shortName
    }
}

/// Задача YouTrack. Идентифицируется `idReadable` (`ATL-1482`).
public struct Issue: Codable, Hashable, Identifiable, Sendable {
    public var idReadable: String
    public var summary: String
    public var project: Project?

    public var id: String { idReadable }
    public var projectName: String { project?.name ?? "" }

    public init(idReadable: String, summary: String, project: Project? = nil) {
        self.idReadable = idReadable
        self.summary = summary
        self.project = project
    }
}

public enum SyncStatus: String, Codable, Sendable {
    case synced
    case pendingCreate
    case pendingUpdate
}

/// Списание: work item в YouTrack, созданный из отрезка (или ждущий отправки).
public struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var issueId: String
    public var workItemId: String?
    /// Фактическая длительность отрезка, мин.
    public var rawMinutes: Int
    /// К списанию (после округления или правки), мин.
    public var minutes: Int
    public var comment: String
    public var type: WorkType
    /// Место под маппинг на типы work item YouTrack, если он понадобится. Сейчас не используется.
    public var youTrackTypeId: String?
    public var start: Date
    public var end: Date
    public var sync: SyncStatus
    public var lastError: String?
    /// Растёт при каждой локальной правке: отличает ответ сервера на старую версию от актуальной.
    public var revision: Int

    public init(
        id: UUID = UUID(), issueId: String, workItemId: String? = nil, rawMinutes: Int, minutes: Int,
        comment: String, type: WorkType, start: Date, end: Date, sync: SyncStatus = .pendingCreate
    ) {
        self.id = id
        self.issueId = issueId
        self.workItemId = workItemId
        self.rawMinutes = rawMinutes
        self.minutes = minutes
        self.comment = comment
        self.type = type
        self.start = start
        self.end = end
        self.sync = sync
        self.revision = 0
    }
}

/// Work item, который нужно удалить в YouTrack (после удаления записи или переноса на другую задачу).
public struct PendingDeletion: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var issueId: String
    public var workItemId: String
    public var minutes: Int
    /// Показать пользователю подтверждение «Удалено из YouTrack».
    public var announce: Bool
    public var lastError: String?

    public init(issueId: String, workItemId: String, minutes: Int, announce: Bool) {
        self.issueId = issueId
        self.workItemId = workItemId
        self.minutes = minutes
        self.announce = announce
    }
}

/// Идущий отрезок учёта.
public struct ActiveSegment: Codable, Hashable, Sendable {
    public var issueId: String
    public var start: Date

    public init(issueId: String, start: Date) {
        self.issueId = issueId
        self.start = start
    }
}

/// Закончившийся отрезок, по которому ждём решения в карточке списания.
public struct SegmentDraft: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var issueId: String
    public var start: Date
    public var end: Date
    public var rawMinutes: Int
    public var minutes: Int
    public var suggestedType: WorkType

    public init(issueId: String, start: Date, end: Date, rawMinutes: Int, minutes: Int, suggestedType: WorkType) {
        self.issueId = issueId
        self.start = start
        self.end = end
        self.rawMinutes = rawMinutes
        self.minutes = minutes
        self.suggestedType = suggestedType
    }
}

public enum DayPhase: String, Codable, Sendable {
    case notStarted
    case started
    case ended
}

public enum TrackerStatus: Equatable, Sendable {
    /// День не начат.
    case notStarted
    /// Учёт идёт.
    case tracking(ActiveSegment)
    /// Пользователь остановил учёт вручную.
    case paused
    /// День начат, но текущей задачи нет.
    case idle
    /// После «Завершить рабочий день».
    case ended
}
