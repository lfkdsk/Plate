import Foundation

/// An imported asset stored in the library. Paths are relative to the library root.
public struct Asset: Codable, Identifiable, Equatable {
    public let id: UUID
    /// Display master (JPEG / HEIF / HIF / ...). If no display master existed in the
    /// source group, this points to a RAW file and the UI must extract an embedded preview.
    public var primary: String
    /// RAW companions stored alongside the primary.
    public var raws: [String]
    /// XMP / AAE sidecars stored alongside the primary.
    public var sidecars: [String]
    /// EXIF DateTimeOriginal when available, else file mtime at import time.
    public var capturedAt: Date?
    /// Pixel dimensions of the primary image. Nil when unreadable (rare, corrupt files).
    /// Required upfront by the justified-grid layout — without aspect ratios it can't pack rows.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Thumbnail path relative to library root, e.g. "Caches/thumbs/<id>-512.jpg".
    public var thumbnail: String?
    /// SHA-256 hex of the primary file's bytes — used for dedup on re-import.
    /// Nil for legacy assets imported before schema v2.
    public var contentHash: String?
    /// Whether the user has flagged this asset as a favorite.
    /// Defaults to false — schema v3 introduced this column with default 0.
    public var isFavorite: Bool
    /// Non-nil ⇒ asset is in "Recently Deleted". Soft-deleted assets stay on disk
    /// and in the row table but are excluded from the main grid query until either
    /// restored (set to nil) or permanently deleted (row removed).
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        primary: String,
        raws: [String] = [],
        sidecars: [String] = [],
        capturedAt: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        thumbnail: String? = nil,
        contentHash: String? = nil,
        isFavorite: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.primary = primary
        self.raws = raws
        self.sidecars = sidecars
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.thumbnail = thumbnail
        self.contentHash = contentHash
        self.isFavorite = isFavorite
        self.deletedAt = deletedAt
    }

    /// Aspect ratio (w/h) used by layout. Falls back to 1.0 when dimensions unknown.
    public var aspectRatio: Double {
        guard let w = pixelWidth, let h = pixelHeight, h > 0 else { return 1.0 }
        return Double(w) / Double(h)
    }

    // Custom Codable: `isFavorite` and `deletedAt` were added in schema v3.
    // Legacy manifest.json libraries don't carry them, so decoding must tolerate
    // missing keys (false / nil) and the synthesized init would fail without
    // defaults baked into the decoder.

    private enum CodingKeys: String, CodingKey {
        case id, primary, raws, sidecars, capturedAt
        case pixelWidth, pixelHeight, thumbnail, contentHash
        case isFavorite, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self,    forKey: .id)
        self.primary       = try c.decode(String.self,  forKey: .primary)
        self.raws          = try c.decodeIfPresent([String].self, forKey: .raws) ?? []
        self.sidecars      = try c.decodeIfPresent([String].self, forKey: .sidecars) ?? []
        self.capturedAt    = try c.decodeIfPresent(Date.self,     forKey: .capturedAt)
        self.pixelWidth    = try c.decodeIfPresent(Int.self,      forKey: .pixelWidth)
        self.pixelHeight   = try c.decodeIfPresent(Int.self,      forKey: .pixelHeight)
        self.thumbnail     = try c.decodeIfPresent(String.self,   forKey: .thumbnail)
        self.contentHash   = try c.decodeIfPresent(String.self,   forKey: .contentHash)
        self.isFavorite    = try c.decodeIfPresent(Bool.self,     forKey: .isFavorite) ?? false
        self.deletedAt     = try c.decodeIfPresent(Date.self,     forKey: .deletedAt)
    }
}
