import UIKit

/// Generates a handful of varied JPEGs at runtime so the iPad shell has real
/// files to push through the **actual** `PlateCore` import pipeline
/// (SHA-256 dedup → ImageIO EXIF/dimension read → thumbnail render → SQLite
/// insert). This stands in for "a camera / SD-card / Files import" so the
/// verification needs no bundled assets. Not production code.
enum DemoImageGenerator {
    static func generate(count: Int, into dir: URL) throws -> [URL] {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Mixed aspect ratios so the justified-style grid has something to pack.
        let sizes: [CGSize] = [
            CGSize(width: 1600, height: 1066),  // 3:2 landscape
            CGSize(width: 1066, height: 1600),  // 2:3 portrait
            CGSize(width: 1280, height: 1280),  // square
            CGSize(width: 1600, height: 900),   // 16:9
        ]
        let palette: [(UInt32, UInt32)] = [
            (0xD97757, 0x8A3F2A), (0x6B8CA3, 0x2E4654), (0x8BA668, 0x3C5230),
            (0xD4A04A, 0x7A5410), (0xC8553D, 0x5E2117), (0xB3A896, 0x4A4034),
        ]

        var urls: [URL] = []
        for i in 0..<count {
            let size = sizes[i % sizes.count]
            let (top, bottom) = palette[i % palette.count]
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                let space = CGColorSpaceCreateDeviceRGB()
                let colors = [UIColor(hex: top).cgColor, UIColor(hex: bottom).cgColor] as CFArray
                if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    cg.drawLinearGradient(grad,
                                          start: .zero,
                                          end: CGPoint(x: size.width, y: size.height),
                                          options: [])
                }
                let label = String(format: "%02d", i + 1)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size.height * 0.42, weight: .heavy),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                ]
                let str = NSAttributedString(string: label, attributes: attrs)
                let bounds = str.size()
                str.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                     y: (size.height - bounds.height) / 2))
            }
            guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
            let url = dir.appendingPathComponent(String(format: "demo-%02d.jpg", i + 1))
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }
}
