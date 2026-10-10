import AppKit
import SwiftUI

/// «О программе TickTrack».
struct AboutView: View {
    private static let email = "nikita.avanti@gmail.com"

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// При запуске через `swift run` Info.plist нет — показываем, что это сборка разработчика.
    private var version: String {
        guard let short = info["CFBundleShortVersionString"] as? String else { return "сборка разработчика" }
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Версия \(short) (сборка \(build))"
    }

    private var copyright: String {
        info["NSHumanReadableCopyright"] as? String ?? "© 2026 Никита Колганов"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "TickTrack").font(.title2.weight(.semibold))
            Text(verbatim: version)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Учёт рабочего времени по задачам YouTrack")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            VStack(spacing: 2) {
                Text("Разработчик — Никита Колганов")
                Link(Self.email, destination: URL(string: "mailto:\(Self.email)")!)
            }
            .padding(.top, 4)
            Text(verbatim: copyright).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 320)
    }
}
