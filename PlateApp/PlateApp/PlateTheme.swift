import AppKit

/// Centralised palette + type system. Translated from the InkType design
/// language: warm neutrals (no pure black), one earned accent, flat hairlines,
/// editorial dark-only — paired with a serif display + system body + mono caps
/// for metadata.
enum PlateColor {
    // Backgrounds — warm neutrals, never #000.
    static let primary  = NSColor(hex: 0x1A1614)   // window base
    static let surface  = NSColor(hex: 0x211C19)   // cards, panels
    static let raised   = NSColor(hex: 0x2A241F)   // hover / popovers
    static let selected = NSColor(hex: 0x342D27)   // pressed / selected row

    // Text — descending warmth.
    static let textPrimary = NSColor(hex: 0xEDE4D3)
    static let textMuted   = NSColor(hex: 0xB3A896)
    static let textSubtle  = NSColor(hex: 0x8A7F6F)
    static let textFaint   = NSColor(hex: 0x5A5147)

    /// The one accent. "Earned, not sprinkled."
    static let accent = NSColor(hex: 0xD97757)

    // Semantics — used sparingly for status, never decoration.
    static let success = NSColor(hex: 0x8BA668)
    static let warning = NSColor(hex: 0xD4A04A)
    static let danger  = NSColor(hex: 0xC8553D)
    static let info    = NSColor(hex: 0x6B8CA3)

    /// Hairlines — single-pixel separators used in place of shadows.
    static let hairline = NSColor(hex: 0x342D27)
}

enum PlateFont {
    /// Display / headlines / leads. NewYork on macOS 11+, Georgia on 10.15.
    static func serif(_ size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      italic: Bool = false) -> NSFont
    {
        let candidates: [String] = italic
            ? ["NewYork-Italic", "Georgia-Italic", "Georgia"]
            : ["NewYork", "Georgia"]
        for name in candidates {
            if let f = NSFont(name: name, size: size) {
                return applyWeight(f, weight: weight)
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// UI body — quiet, designed to vanish. SF Pro at native sizes.
    static func body(_ size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Metadata + code — SF Mono, used in CAPS for dates / IDs / sizes.
    static func mono(_ size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func applyWeight(_ font: NSFont, weight: NSFont.Weight) -> NSFont {
        guard weight != .regular else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8)  & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
