import Foundation

public enum AssetKind {
    case displayMaster
    case raw
    case sidecar
    case unknown

    public static func classify(pathExtension ext: String) -> AssetKind {
        let lower = ext.lowercased()
        if Self.displayMasters.contains(lower) { return .displayMaster }
        if Self.raws.contains(lower) { return .raw }
        if Self.sidecars.contains(lower) { return .sidecar }
        return .unknown
    }

    public static let displayMasters: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"
    ]

    public static let raws: Set<String> = [
        "3fr", "fff",            // Hasselblad
        "nef", "nrw",            // Nikon
        "cr2", "cr3", "crw",     // Canon
        "arw", "srf", "sr2",     // Sony
        "raf",                   // Fuji
        "dng",                   // Adobe / generic
        "orf",                   // Olympus
        "rw2",                   // Panasonic
        "pef", "ptx",            // Pentax
        "srw",                   // Samsung
        "rwl",                   // Leica
        "iiq"                    // Phase One
    ]

    public static let sidecars: Set<String> = [
        "xmp", "aae"
    ]

    public static var allSupportedExtensions: Set<String> {
        displayMasters.union(raws).union(sidecars)
    }
}
