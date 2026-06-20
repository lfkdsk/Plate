import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import CoreMedia

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
    /// Stills go through system ImageIO — natively handles JPEG / HEIF / TIFF and RAW
    /// formats including Hasselblad 3FR/FFF, Canon CR2/CR3, Nikon NEF, Sony ARW, Adobe
    /// DNG, etc. Movie files (`AssetKind.video`) get a poster frame extracted with
    /// AVFoundation instead, then the identical JPEG-writing tail. A Live Photo's
    /// thumbnail comes from its *still* master (the primary), so it lands on the
    /// ImageIO path like any other still.
    @discardableResult
    public func generate(
        from source: URL,
        maxPixel: Int,
        to destination: URL,
        quality: Float = 0.85
    ) throws -> URL {
        let cgImage: CGImage
        if AssetKind.classify(pathExtension: source.pathExtension) == .video {
            guard let frame = Self.videoPosterFrame(from: source, maxPixel: maxPixel) else {
                throw ThumbnailError.thumbnailGenerationFailed(source)
            }
            cgImage = frame
        } else {
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
            guard let img = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, primaryOpts as CFDictionary)
                ?? CGImageSourceCreateThumbnailAtIndex(cgSource, 0, fallbackOpts as CFDictionary) else {
                throw ThumbnailError.thumbnailGenerationFailed(source)
            }
            cgImage = img
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

    /// Extract a representative still from a movie. Honors the track's rotation
    /// (`appliesPreferredTrackTransform`) and downsamples to `maxPixel` during
    /// decode (`maximumSize`) so we never haul a 4K frame into memory just to
    /// shrink it. The frame is taken a beat in (≈1s, clamped to the clip's own
    /// length) because the very first frame is frequently a black fade-in.
    /// Generous time tolerances let AVFoundation snap to the nearest keyframe —
    /// the poster doesn't need to be frame-exact, and this keeps it fast.
    /// Public so UI code (the import picker preview) can render a movie tile
    /// off the same path the importer uses.
    public static func videoPosterFrame(from url: URL, maxPixel: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard !asset.tracks(withMediaType: .video).isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let seconds = CMTimeGetSeconds(asset.duration)
        let target = (seconds.isFinite && seconds > 0)
            ? CMTime(seconds: min(1.0, seconds / 2), preferredTimescale: 600)
            : CMTime.zero
        return try? generator.copyCGImage(at: target, actualTime: nil)
    }
}
