import Foundation

/// What kind of media an `Asset` is. Drives how the UI renders it: a still
/// shows an image, a `video` plays in an AVPlayer, a `livePhoto` shows the
/// still and plays its short motion companion on demand.
///
/// Stored on the row as a lowercased string (schema v6). The raw values are
/// part of the on-disk format — don't rename them. New cases must default to
/// `.image` on decode so older libraries (and the legacy manifest.json) keep
/// loading.
public enum MediaType: String, Codable, Equatable {
    /// A single still image — JPEG / HEIF / PNG / TIFF / RAW. The historical
    /// (and overwhelmingly common) case; everything before schema v6 is this.
    case image
    /// A standalone movie file (`primary` is the video itself, no still master).
    case video
    /// An Apple Live Photo: `primary` is the still master and `motionPath`
    /// points at the paired `.mov` motion clip captured alongside it.
    case livePhoto

    /// Tolerant decode of the stored string — an unrecognized value (written by
    /// some future build) reads back as `.image` rather than throwing, so a
    /// newer library never hard-fails an older reader on this field alone.
    public init(storedValue: String?) {
        switch storedValue?.lowercased() {
        case "video":     self = .video
        case "livephoto": self = .livePhoto
        default:          self = .image
        }
    }
}
