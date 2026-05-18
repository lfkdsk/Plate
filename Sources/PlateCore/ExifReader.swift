import Foundation
import ImageIO

public struct ImageMetadata {
    public var capturedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
}

public enum ExifReader {
    /// Read capture date + pixel dimensions in a single ImageIO source open.
    /// `capturedAt` falls back to file mtime when no EXIF/TIFF date is present.
    /// Honors EXIF Orientation: width/height are returned in display orientation.
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
