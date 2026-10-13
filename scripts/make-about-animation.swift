// Готовит анимацию для «О программе»: анимированный WebP → APNG нужного размера.
// WebP с кадрами 1024×1024 декодируется около 2 с, APNG 192×192 — за миллисекунды, поэтому в приложение кладём его.
// Использование: swift scripts/make-about-animation.swift [Support/AboutAnimation.webp] [Support/AboutAnimation.png]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let input = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Support/AboutAnimation.webp")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Support/AboutAnimation.png")
/// 96 pt на экране Retina.
let pixels = 192

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { fatalError("Не читается \(input.path)") }
let count = CGImageSourceGetCount(source)
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, count, nil) else {
    fatalError("Не создаётся \(output.path)")
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
let options = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: pixels,
    kCGImageSourceCreateThumbnailWithTransform: true,
] as CFDictionary
for i in 0..<count {
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options) else { fatalError("Кадр \(i) не читается") }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
    let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
    let delay = webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double ?? webp?[kCGImagePropertyWebPDelayTime] as? Double ?? 0.04
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Не записался \(output.path)") }
print("Готово: \(output.path), кадров \(count)")
