import Foundation

/// Single entry point the import / rebuild pipeline calls to extract metadata
/// from an asset's primary file, regardless of whether that file is a still or
/// a movie. Routes movies to `VideoMetadataReader` (AVFoundation) and everything
/// else — stills and RAW, including a Live Photo's still master — to
/// `ExifReader` (ImageIO). Callers no longer branch on file type themselves.
public enum MediaMetadataReader {
    public static func readMetadata(for url: URL) -> ImageMetadata {
        if AssetKind.classify(pathExtension: url.pathExtension) == .video {
            return VideoMetadataReader.read(for: url)
        }
        return ExifReader.readMetadata(for: url)
    }
}
