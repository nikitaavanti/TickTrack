import AppKit
import TickTrackCore

/// Переход к задаче в YouTrack и копирование ссылки на неё.
extension AppModel {
    /// `nil`, если адрес сервера не задан: тогда ID показывается обычным текстом.
    func issueURL(_ id: String) -> URL? {
        YouTrackClient.issueURL(server: settings.serverURL, issueId: id)
    }

    /// Открывает задачу в браузере по умолчанию. Меню при этом закрывается.
    func openInYouTrack(_ id: String) {
        guard let url = issueURL(id) else { return }
        closeMenu()
        NSWorkspace.shared.open(url)
    }

    func copyIssueLink(_ id: String) {
        guard let url = issueURL(id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        closeMenu()
    }

    /// «VEG-4499 Название задачи», где ID — ссылка на задачу. Там, где ссылки не вставляются, — просто текст.
    func copyIssueWithTitle(_ id: String) {
        let title = title(of: id)
        let plain = title.isEmpty ? id : "\(id) \(title)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let url = issueURL(id) {
            let rich = NSMutableAttributedString(string: id, attributes: [.link: url])
            if !title.isEmpty { rich.append(NSAttributedString(string: " " + title)) }
            if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pasteboard.setData(rtf, forType: .rtf)
            }
            let html = "<a href=\"\(Self.escapeHTML(url.absoluteString))\">\(Self.escapeHTML(id))</a>" + (title.isEmpty ? "" : " " + Self.escapeHTML(title))
            pasteboard.setString(html, forType: .html)
        }
        pasteboard.setString(plain, forType: .string)
        closeMenu()
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// ⌘-клик по строке задачи открывает её в YouTrack вместо обычного действия.
    var isCommandClick: Bool {
        NSEvent.modifierFlags.contains(.command)
    }
}
