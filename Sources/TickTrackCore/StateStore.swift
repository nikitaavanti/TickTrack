import Foundation

/// Хранит `TrackerState` в JSON-файле в Application Support.
public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL = StateStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "TickTrack", directoryHint: .isDirectory).appending(path: "state.json")
    }

    /// Повреждённый файл не теряется: он переименовывается рядом, а учёт начинается с чистого состояния.
    public func load() -> TrackerState {
        guard let data = try? Data(contentsOf: url) else { return TrackerState() }
        do {
            return try JSONDecoder().decode(TrackerState.self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return TrackerState()
        }
    }

    public func save(_ state: TrackerState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
