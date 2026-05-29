import UIKit

/// UIKit mirror of `PlateApp/PlateTheme.swift` — the same warm-neutral dark
/// palette (no pure black, one earned accent) so the iPad shell reads as the
/// same product as the macOS app. Kept deliberately small: a port would share
/// these values via a tiny platform-agnostic `PlateDesign` module, but for the
/// proof we just transcribe them.
enum PlateColor {
    static let primary  = UIColor(hex: 0x1A1614)   // window base
    static let surface  = UIColor(hex: 0x211C19)   // cards, panels
    static let raised   = UIColor(hex: 0x2A241F)   // hover / popovers
    static let selected = UIColor(hex: 0x342D27)   // pressed / selected

    static let textPrimary = UIColor(hex: 0xEDE4D3)
    static let textMuted   = UIColor(hex: 0xB3A896)
    static let textSubtle  = UIColor(hex: 0x8A7F6F)

    static let accent = UIColor(hex: 0xD97757)   // the one accent
    static let hairline = UIColor(hex: 0x342D27)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8)  & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}
