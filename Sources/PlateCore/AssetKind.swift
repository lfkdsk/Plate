import Foundation

public enum AssetKind {
    case displayMaster
    case raw
    case video
    case sidecar
    case unknown

    public static func classify(pathExtension ext: String) -> AssetKind {
        let lower = ext.lowercased()
        if Self.displayMasters.contains(lower) { return .displayMaster }
        if Self.raws.contains(lower) { return .raw }
        if Self.videos.contains(lower) { return .video }
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

    /// Movie containers. `mov` / `mp4` / `m4v` cover the overwhelming majority
    /// (iPhone, Hasselblad/most cameras' clips, Live Photo motion). The rest are
    /// included so a mixed card import doesn't silently drop them — AVFoundation
    /// reads them all for frame extraction + playback.
    public static let videos: Set<String> = [
        "mov", "mp4", "m4v",     // QuickTime / MPEG-4 (incl. Live Photo motion)
        "hevc",                  // raw HEVC elementary stream
        "avi", "mpg", "mpeg",    // legacy
        "mkv", "webm",           // Matroska / WebM
        "3gp", "3g2"             // mobile
    ]

    public static let sidecars: Set<String> = [
        "xmp", "aae"
    ]

    public static var allSupportedExtensions: Set<String> {
        displayMasters.union(raws).union(videos).union(sidecars)
    }
}
