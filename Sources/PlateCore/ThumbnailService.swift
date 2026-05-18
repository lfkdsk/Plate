import Foundation
import ImageIO
import CoreGraphics

public enum ThumbnailError: Error, CustomStringConvertible {
    case sourceUnreadable(URL)
    case thumbnailGenerationFailed(URL)
    case destinationCreateFailed(URL)
    case destinationFinalizeFailed(URL)

    public var description: String {
        switch self {
        case .sourceUnreadable(let u): return "Cannot open image source: \(u.path)"
        case .thumbnailGenerationFailed(let u): return "Failed to generate thumbnail for: \(u.path)"
        case .destinationCreateFailed(let u): return "Cannot create destination: \(u.path)"
        case .destinationFinalizeFailed(let u): return "Failed to write destination: \(u.path)"
        }
    }
}

public struct ThumbnailService {
    public init() {}

    /// Generate a JPEG thumbnail at `maxPixel` (longest edge) and write it to `destination`.
    /// Relies on system ImageIO — natively handles JPEG / HEIF / TIFF and RAW formats
    /// including Hasselblad 3FR/FFF, Canon CR2/CR3, Nikon NEF, Sony ARW, Adobe DNG, etc.
    @discardableResult
    public func generate(
        from source: URL,
        maxPixel: Int,
        to destination: URL,
        quality: Float = 0.85
    ) throws -> URL {
        guard let cgSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ThumbnailError.sourceUnreadable(source)
        }
        // Primary path: force a full re-render at our target size. Best quality
        // and never returns the tiny embedded JFIF thumb.
        let primaryOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        // Fallback: some post-processed RAWs (e.g. Phocus-denoised 3FR) fail
        // the "decode main image" path; their embedded preview is fine though.
        // We accept any embedded thumbnail rather than refusing the asset.
        let fallbackOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        let cgImage = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, primaryOpts as CFDictionary)
            ?? CGImageSourceCreateThumbnailAtIndex(cgSource, 0, fallbackOpts as CFDictionary)
        guard let cgImage = cgImage else {
            throw ThumbnailError.thumbnailGenerationFailed(source)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // "public.jpeg" is a stable system UTI from 10.10+; avoid UTType (macOS 11+).
        let jpegUTI = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, jpegUTI, 1, nil) else {
            throw ThumbnailError.destinationCreateFailed(destination)
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ThumbnailError.destinationFinalizeFailed(destination)
        }
        return destination
    }
}
