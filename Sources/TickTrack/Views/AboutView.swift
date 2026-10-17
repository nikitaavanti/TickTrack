import AppKit
import ImageIO
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
        info["NSHumanReadableCopyright"] as? String ?? "© 2026 Никита Колганов."
    }

    var body: some View {
        VStack(spacing: 10) {
            AppIconAnimation(size: 96)
            Text(verbatim: "TickTrack").font(.title2.weight(.semibold))
            Text(verbatim: version)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Учёт рабочего времени по задачам YouTrack")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            VStack(spacing: 2) {
                Text("Создатель — Никита Колганов")
                Link(Self.email, destination: URL(string: "mailto:\(Self.email)")!)
            }
            .padding(.top, 4)
            VStack(spacing: 8) {
                // Копирайт, лицензия со ссылкой на текст и отказ от гарантий — «уместные правовые уведомления» GPL v3 (§0, §5d).
                VStack(spacing: 2) {
                    Text(verbatim: copyright)
                    Text("Распространяется по лицензии [GNU\u{00A0}GPL\u{00A0}v3](https://www.gnu.org/licenses/gpl-3.0.html) без\u{00A0}каких-либо гарантий.")
                }
                // Оговорка о чужом товарном знаке: приложение не выдаёт себя за продукт JetBrains.
                // Неразрывные пробелы не дают строке оборваться на «не» или разорвать «JetBrains s.r.o.».
                Text("YouTrack — зарегистрированный товарный знак JetBrains\u{00A0}s.r.o. TickTrack — независимое приложение, не\u{00A0}связанное с JetBrains\u{00A0}s.r.o. и не\u{00A0}одобренное ею.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 320)
    }
}

/// Анимированный кот вместо иконки — в «О программе» и в вопросе при выходе: кадры из `AboutAnimation.png` (APNG)
/// в ресурсах приложения. Без файла (запуск через `swift run`) и при «Уменьшить движение» — обычная иконка приложения.
struct AppIconAnimation: View {
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !reduceMotion, let animation = Self.animation {
                AnimationLayer(animation: animation)
                    .clipShape(.rect(cornerRadius: size * 0.22))
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable()
            }
        }
        .frame(width: size, height: size)
    }

    /// Готовится один раз, при первом открытии окна: декодируется за доли секунды.
    private static let animation = load()

    /// Кадры и анимация смены кадров.
    private static func load() -> CAKeyframeAnimation? {
        guard let url = Bundle.main.url(forResource: "AboutAnimation", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [CGImage] = []
        var durations: [Double] = []
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double ?? png?[kCGImagePropertyAPNGDelayTime] as? Double
            frames.append(image)
            durations.append(max(delay ?? 0.04, 0.02))
        }
        guard frames.count > 1 else { return nil }
        let total = durations.reduce(0, +)
        var start = 0.0
        var keyTimes: [NSNumber] = []
        for duration in durations {
            keyTimes.append(NSNumber(value: start / total))
            start += duration
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Слой с покадровой анимацией. Её крутит Core Animation, а не SwiftUI: так она играет сразу,
/// даже если окно открылось у неактивного приложения и SwiftUI не перерисовывает его до первого клика.
private struct AnimationLayer: NSViewRepresentable {
    let animation: CAKeyframeAnimation

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = view.layer!
        layer.contentsGravity = .resizeAspect
        layer.contents = animation.values?.first
        layer.add(animation, forKey: "frames")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
