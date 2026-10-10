import AppKit
import Carbon.HIToolbox
import Security
import TickTrackCore

/// Токен YouTrack в Keychain.
enum Keychain {
    private static let service = "TickTrack.YouTrack"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Глобальное сочетание через Carbon `RegisterEventHotKey`: не требует разрешения на универсальный доступ.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ shortcut: HotKeyShortcut) {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5454_524B), id: 1) // 'TTRK'
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension HotKeyShortcut {
    /// Сочетание из нажатия в поле записи. `nil`, если нет ни ⌘, ни ⌥, ни ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: Int = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        let key = Self.keyName(event)
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: UInt32(carbon), display: symbols + key)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Пробел"
        case kVK_Return: return "↵"
        case kVK_Tab: return "⇥"
        default:
            // Латинская буква по коду клавиши, чтобы подпись не зависела от раскладки.
            if let latin = event.characters(byApplyingModifiers: [])?.uppercased(), latin.count == 1,
               latin.unicodeScalars.allSatisfy({ $0.isASCII }) {
                return latin
            }
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

/// Текстовые форматы интерфейса.
enum Fmt {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func hm(_ minutes: Int) -> String { TimeMath.hm(minutes) }

    static func short(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

