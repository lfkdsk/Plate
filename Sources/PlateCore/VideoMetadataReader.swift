import Foundation
import AVFoundation
import CoreMedia

/// Pulls the same `ImageMetadata` shape out of a movie file that `ExifReader`
/// pulls out of a still, so the import/rebuild pipeline can treat both
/// uniformly. Fills pixel dimensions (in display orientation), duration, the
/// capture date, and — when the camera wrote one (iPhone always does) — GPS
/// coordinates from the QuickTime `location.ISO6709` tag.
///
/// Uses AVFoundation's synchronous accessors. That's intentional: import and
/// "Rebuild Library Data" already run off the main thread, exactly like the
/// ImageIO reads in `ExifReader`.
public enum VideoMetadataReader {

    public static func read(for url: URL) -> ImageMetadata {
        var meta = ImageMetadata()
        let asset = AVURLAsset(url: url)

        // Dimensions: a video track's natural size is pre-rotation; applying the
        // preferred transform yields the displayed (upright) size, matching how
        // ExifReader honors EXIF orientation. abs() because the transform can
        // flip an axis negative.
        if let track = asset.tracks(withMediaType: .video).first {
            let displayed = track.naturalSize.applying(track.preferredTransform)
            let w = Int(abs(displayed.width).rounded())
            let h = Int(abs(displayed.height).rounded())
            if w > 0 { meta.pixelWidth = w }
            if h > 0 { meta.pixelHeight = h }
        }

        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { meta.duration = seconds }

        meta.capturedAt = creationDate(of: asset)

        if let (lat, lon) = location(of: asset) {
            meta.latitude = lat
            meta.longitude = lon
        }

        // Fall back to file mtime when the container carried no creation date —
        // same contract as ExifReader, so a dateless clip still sorts sensibly.
        if meta.capturedAt == nil {
            meta.capturedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return meta
    }

    /// The container's creation date. `AVAsset.creationDate` covers QuickTime/MP4
    /// (`com.apple.quicktime.creationdate`, `©day`); fall back to scanning common
    /// metadata for the rare file whose date only lives there.
    private static func creationDate(of asset: AVURLAsset) -> Date? {
        if let item = asset.creationDate, let date = item.dateValue {
            return date
        }
        for item in AVMetadataItem.metadataItems(
            from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyCreationDate,
            keySpace: .common) {
            if let date = item.dateValue { return date }
        }
        return nil
    }

    /// Parse the QuickTime ISO-6709 location string into signed decimal degrees.
    private static func location(of asset: AVURLAsset) -> (lat: Double, lon: Double)? {
        let keySpaces: [AVMetadataKeySpace] = [.quickTimeMetadata, .quickTimeUserData, .iTunes]
        for keySpace in keySpaces {
            let items = AVMetadataItem.metadataItems(
                from: asset.metadata, withKey: nil, keySpace: keySpace)
            for item in items {
                let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
                guard key.lowercased().contains("location"),
                      let value = item.stringValue,
                      let coords = parseISO6709(value) else { continue }
                return coords
            }
        }
        return nil
    }

    /// ISO 6709 packs coordinates as sign-prefixed decimal tokens with no
    /// separator, e.g. `+37.3318-122.0312+010.12/` (lat, lon, optional altitude,
    /// trailing solidus). Split on each leading sign; first two tokens are the
    /// latitude and longitude.
    static func parseISO6709(_ string: String) -> (lat: Double, lon: Double)? {
        var tokens: [String] = []
        var current = ""
        for ch in string {
            if ch == "+" || ch == "-" {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
            } else if ch == "/" {
                break
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard tokens.count >= 2,
              let lat = Double(tokens[0]),
              let lon = Double(tokens[1]) else { return nil }
        return (lat, lon)
    }
}
