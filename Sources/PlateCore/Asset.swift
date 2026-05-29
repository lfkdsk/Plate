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

    // EXIF shooting metadata (schema v5). All optional — older assets imported
    // before v5, and files that carry no EXIF (screenshots, scans, stripped
    // exports), leave these nil. Re-extracted by "Rebuild Library Data".
    /// Camera manufacturer (TIFF Make), e.g. "Hasselblad".
    public var cameraMake: String?
    /// Camera body (TIFF Model), e.g. "X2D 100C".
    public var cameraModel: String?
    /// Lens model (EXIF LensModel), e.g. "XCD 4/45P".
    public var lensModel: String?
    /// Focal length in millimetres, as shot (not 35mm-equivalent).
    public var focalLength: Double?
    /// Aperture as an f-number, e.g. 4.0 for f/4.
    public var aperture: Double?
    /// Shutter speed in seconds, e.g. 0.004 for 1/250s.
    public var shutterSpeed: Double?
    /// ISO sensitivity.
    public var iso: Int?
    /// GPS latitude in signed decimal degrees (south negative).
    public var latitude: Double?
    /// GPS longitude in signed decimal degrees (west negative).
    public var longitude: Double?

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
        deletedAt: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        shutterSpeed: Double? = nil,
        iso: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
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
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Human-readable camera name combining make + model, de-duplicating the
    /// common case where the model already embeds the make (e.g. Make "NIKON
    /// CORPORATION", Model "NIKON Z 7" → "NIKON Z 7"). Nil when both are absent.
    public var cameraName: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            // Many models repeat the brand; collapse "Canon Canon EOS R5".
            if model.lowercased().hasPrefix(make.lowercased()) { return model }
            // Some makes are verbose ("NIKON CORPORATION"); prefer the model when
            // it already names the brand family.
            let firstMakeWord = make.split(separator: " ").first.map(String.init) ?? make
            if model.lowercased().contains(firstMakeWord.lowercased()) { return model }
            return "\(make) \(model)"
        case let (make?, nil):  return make
        case let (nil, model?): return model
        case (nil, nil):        return nil
        }
    }

    /// Aspect ratio (w/h) used by layout. Falls back to 1.0 when dimensions unknown.
    public var aspectRatio: Double {
        guard let w = pixelWidth, let h = pixelHeight, h > 0 else { return 1.0 }
        return Double(w) / Double(h)
    }

    /// Short format label that folds RAW companions into the base type:
    /// "JPEG", "HEIF + RAW", "TIFF", "RAW", … When the primary is itself a RAW
    /// (no display master in the group) it's simply "RAW". Single source of
    /// truth shared by the grid's corner badge and the Statistics "by format"
    /// breakdown so the two never drift apart.
    public var formatLabel: String {
        let ext = (primary as NSString).pathExtension.lowercased()
        let base: String
        switch ext {
        case "jpg", "jpeg":          base = "JPEG"
        case "heic", "heif", "hif":  base = "HEIF"
        case "png":                  base = "PNG"
        case "tif", "tiff":          base = "TIFF"
        default:
            // A RAW primary means the group had no display master — never
            // "RAW + RAW"; just "RAW". Other/unknown types show their extension.
            if AssetKind.raws.contains(ext) { return "RAW" }
            base = ext.uppercased()
        }
        return raws.isEmpty ? base : "\(base) + RAW"
    }

    // Custom Codable: `isFavorite` and `deletedAt` were added in schema v3.
    // Legacy manifest.json libraries don't carry them, so decoding must tolerate
    // missing keys (false / nil) and the synthesized init would fail without
    // defaults baked into the decoder.

    private enum CodingKeys: String, CodingKey {
        case id, primary, raws, sidecars, capturedAt
        case pixelWidth, pixelHeight, thumbnail, contentHash
        case isFavorite, deletedAt
        case cameraMake, cameraModel, lensModel, focalLength
        case aperture, shutterSpeed, iso, latitude, longitude
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
        self.cameraMake    = try c.decodeIfPresent(String.self,   forKey: .cameraMake)
        self.cameraModel   = try c.decodeIfPresent(String.self,   forKey: .cameraModel)
        self.lensModel     = try c.decodeIfPresent(String.self,   forKey: .lensModel)
        self.focalLength   = try c.decodeIfPresent(Double.self,   forKey: .focalLength)
        self.aperture      = try c.decodeIfPresent(Double.self,   forKey: .aperture)
        self.shutterSpeed  = try c.decodeIfPresent(Double.self,   forKey: .shutterSpeed)
        self.iso           = try c.decodeIfPresent(Int.self,      forKey: .iso)
        self.latitude      = try c.decodeIfPresent(Double.self,   forKey: .latitude)
        self.longitude     = try c.decodeIfPresent(Double.self,   forKey: .longitude)
    }
}
