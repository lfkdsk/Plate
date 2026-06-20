import Foundation
import ImageIO

public struct ImageMetadata {
    public var capturedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Camera manufacturer (TIFF Make), e.g. "Hasselblad", "SONY". Trimmed.
    public var cameraMake: String?
    /// Camera body (TIFF Model), e.g. "X2D 100C", "ILCE-7M4". Trimmed.
    public var cameraModel: String?
    /// Lens model (EXIF LensModel), e.g. "XCD 4/45P".
    public var lensModel: String?
    /// Focal length in millimetres (EXIF FocalLength), as shot — not 35mm equiv.
    public var focalLength: Double?
    /// Aperture as an f-number (EXIF FNumber), e.g. 4.0 for f/4.
    public var aperture: Double?
    /// Shutter speed in seconds (EXIF ExposureTime), e.g. 0.004 for 1/250s.
    public var shutterSpeed: Double?
    /// ISO sensitivity (first EXIF ISOSpeedRatings value).
    public var iso: Int?
    /// GPS latitude in signed decimal degrees (south negative).
    public var latitude: Double?
    /// GPS longitude in signed decimal degrees (west negative).
    public var longitude: Double?
    /// Playback duration in seconds — set only for video assets (the EXIF/
    /// ImageIO path never fills it; `VideoMetadataReader` does).
    public var duration: Double?
}

public enum ExifReader {
    /// Read capture date, pixel dimensions, and shooting metadata in a single
    /// ImageIO source open. `capturedAt` falls back to file mtime when no
    /// EXIF/TIFF date is present. Honors EXIF Orientation: width/height are
    /// returned in display orientation. Camera / lens / exposure / GPS fields
    /// are nil when the file carries no such metadata (common for screenshots,
    /// scans, and exported masters that stripped EXIF).
    public static func readMetadata(for url: URL) -> ImageMetadata {
        var metadata = ImageMetadata()
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            metadata.capturedAt = exifDate(from: props)

            var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            // EXIF Orientation 5-8 = transposed; swap so dimensions match display.
            if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
               (5...8).contains(orientation) {
                swap(&w, &h)
            }
            metadata.pixelWidth = w
            metadata.pixelHeight = h

            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

            metadata.cameraMake  = cleanString(tiff?[kCGImagePropertyTIFFMake])
            metadata.cameraModel = cleanString(tiff?[kCGImagePropertyTIFFModel])
            metadata.lensModel   = cleanString(exif?[kCGImagePropertyExifLensModel])
            metadata.focalLength = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
            metadata.aperture    = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            metadata.shutterSpeed = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
               let first = isoArray.first {
                metadata.iso = first.intValue
            } else if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber)?.intValue {
                metadata.iso = iso
            }

            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                metadata.latitude = signedCoordinate(
                    value: gps[kCGImagePropertyGPSLatitude],
                    ref: gps[kCGImagePropertyGPSLatitudeRef], negativeRef: "S")
                metadata.longitude = signedCoordinate(
                    value: gps[kCGImagePropertyGPSLongitude],
                    ref: gps[kCGImagePropertyGPSLongitudeRef], negativeRef: "W")
            }
        }
        if metadata.capturedAt == nil {
            metadata.capturedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return metadata
    }

    /// Convenience — capture date only. Prefer `readMetadata(for:)` when also using dimensions.
    public static func captureDate(for url: URL) -> Date? {
        readMetadata(for: url).capturedAt
    }

    private static func exifDate(from props: [CFString: Any]) -> Date? {
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = parseExifDate(str) {
            return date
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let str = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = parseExifDate(str) {
            return date
        }
        return nil
    }

    /// Trim whitespace/NULs and drop empties — EXIF string fields are often
    /// space- or NUL-padded to a fixed width by the camera firmware.
    private static func cleanString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// GPS coordinates are stored as an unsigned magnitude plus a hemisphere
    /// ref char ("N"/"S", "E"/"W"). Combine into a signed decimal degree.
    private static func signedCoordinate(value: Any?, ref: Any?, negativeRef: String) -> Double? {
        guard let magnitude = (value as? NSNumber)?.doubleValue else { return nil }
        if let r = (ref as? String)?.uppercased(), r == negativeRef {
            return -magnitude
        }
        return magnitude
    }

    // EXIF date strings have format "yyyy:MM:dd HH:mm:ss" in local time with no zone info.
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func parseExifDate(_ s: String) -> Date? {
        exifFormatter.date(from: s)
    }
}
