import Carbon.HIToolbox
import Foundation
import Observation
import TickTrackCore

enum MenuBarTitleMode: String, CaseIterable, Identifiable {
    case idOnly
    case idAndTitle

    var id: Self { self }

    var title: String {
        switch self {
        case .idOnly: "Только ID"
        case .idAndTitle: "ID и начало названия"
        }
    }
}

/// Глобальное сочетание клавиш в терминах Carbon.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let standard = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧T"
    )
}

/// Настройки из ТЗ. Хранятся в `UserDefaults`, токен — в Keychain.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var serverURL: String { didSet { defaults.set(serverURL, forKey: Key.serverURL) } }
    var token: String { didSet { Keychain.save(token, account: Key.token) } }
    var inProgressQuery: String { didSet { defaults.set(inProgressQuery, forKey: Key.inProgressQuery) } }
    /// «Мои проекты» — короткие имена (`ATLAS`, `VEG`). Пусто — работаем со всеми проектами.
    var myProjects: [String] { didSet { defaults.set(myProjects, forKey: Key.myProjects) } }

    var autopauseEnabled: Bool { didSet { defaults.set(autopauseEnabled, forKey: Key.autopauseEnabled) } }
    var autopauseMinutes: Int { didSet { defaults.set(autopauseMinutes, forKey: Key.autopauseMinutes) } }
    var forgotEnabled: Bool { didSet { defaults.set(forgotEnabled, forKey: Key.forgotEnabled) } }
    var forgotMinutes: Int { didSet { defaults.set(forgotMinutes, forKey: Key.forgotMinutes) } }
    var morningEnabled: Bool { didSet { defaults.set(morningEnabled, forKey: Key.morningEnabled) } }
    /// Минуты от полуночи.
    var morningTime: Int { didSet { defaults.set(morningTime, forKey: Key.morningTime) } }

    var minimumMinutes: Int { didSet { defaults.set(minimumMinutes, forKey: Key.minimumMinutes) } }
    var cardEnabled: Bool { didSet { defaults.set(cardEnabled, forKey: Key.cardEnabled) } }
    var cardSeconds: Int { didSet { defaults.set(cardSeconds, forKey: Key.cardSeconds) } }
    var defaultType: WorkType { didSet { defaults.set(defaultType.rawValue, forKey: Key.defaultType) } }
    /// Дневная норма в минутах, шаг — полчаса.
    var dailyNormMinutes: Int { didSet { defaults.set(dailyNormMinutes, forKey: Key.dailyNormMinutes) } }

    var menuBarMode: MenuBarTitleMode { didSet { defaults.set(menuBarMode.rawValue, forKey: Key.menuBarMode) } }
    var hotKey: HotKeyShortcut {
        didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: Key.hotKey) }
    }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.inProgressQuery: "for: me State: {In Progress}",
            Key.autopauseEnabled: true,
            Key.autopauseMinutes: 10,
            Key.forgotEnabled: true,
            Key.forgotMinutes: 10,
            Key.morningEnabled: true,
            Key.morningTime: 9 * 60,
            Key.minimumMinutes: 2,
            Key.cardEnabled: true,
            Key.cardSeconds: 10,
            Key.defaultType: WorkType.unspecified.rawValue,
            Key.dailyNormMinutes: 7 * 60,
            Key.menuBarMode: MenuBarTitleMode.idOnly.rawValue,
            Key.launchAtLogin: true,
        ])
        serverURL = defaults.string(forKey: Key.serverURL) ?? ""
        token = Keychain.read(account: Key.token) ?? ""
        inProgressQuery = defaults.string(forKey: Key.inProgressQuery) ?? ""
        myProjects = defaults.stringArray(forKey: Key.myProjects) ?? []
        autopauseEnabled = defaults.bool(forKey: Key.autopauseEnabled)
        autopauseMinutes = max(1, defaults.integer(forKey: Key.autopauseMinutes))
        forgotEnabled = defaults.bool(forKey: Key.forgotEnabled)
        forgotMinutes = max(1, defaults.integer(forKey: Key.forgotMinutes))
        morningEnabled = defaults.bool(forKey: Key.morningEnabled)
        morningTime = defaults.integer(forKey: Key.morningTime)
        minimumMinutes = max(0, defaults.integer(forKey: Key.minimumMinutes))
        cardEnabled = defaults.bool(forKey: Key.cardEnabled)
        cardSeconds = max(5, defaults.integer(forKey: Key.cardSeconds))
        defaultType = WorkType(rawValue: defaults.string(forKey: Key.defaultType) ?? "") ?? .unspecified
        dailyNormMinutes = DailyNorm(minutes: defaults.integer(forKey: Key.dailyNormMinutes)).minutes
        menuBarMode = MenuBarTitleMode(rawValue: defaults.string(forKey: Key.menuBarMode) ?? "") ?? .idOnly
        hotKey = defaults.data(forKey: Key.hotKey).flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) } ?? .standard
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    var rules: WriteOffRules {
        WriteOffRules(minimumMinutes: minimumMinutes)
    }

    var dailyNorm: DailyNorm { DailyNorm(minutes: dailyNormMinutes) }

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private enum Key {
        static let serverURL = "serverURL"
        static let token = "youtrackToken"
        static let inProgressQuery = "inProgressQuery"
        static let myProjects = "myProjects"
        static let autopauseEnabled = "autopauseEnabled"
        static let autopauseMinutes = "autopauseMinutes"
        static let forgotEnabled = "forgotEnabled"
        static let forgotMinutes = "forgotMinutes"
        static let morningEnabled = "morningEnabled"
        static let morningTime = "morningTime"
        static let minimumMinutes = "minimumMinutes"
        static let cardEnabled = "cardEnabled"
        static let cardSeconds = "cardSeconds"
        static let defaultType = "defaultType"
        static let dailyNormMinutes = "dailyNormMinutes"
        static let menuBarMode = "menuBarMode"
        static let hotKey = "hotKey"
        static let launchAtLogin = "launchAtLogin"
    }
}
