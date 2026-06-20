import Foundation

/// A logical asset prior to library import — a group of source files sharing a basename.
public struct AssetPair: Equatable {
    public var primary: URL
    public var raws: [URL]
    public var sidecars: [URL]
    /// The paired motion `.mov` of a Live Photo (still primary + motion clip).
    /// Nil for stills and standalone videos — a video's playable file is `primary`.
    public var motion: URL?

    public init(primary: URL, raws: [URL] = [], sidecars: [URL] = [], motion: URL? = nil) {
        self.primary = primary
        self.raws = raws
        self.sidecars = sidecars
        self.motion = motion
    }

    public var allFiles: [URL] {
        [primary] + raws + sidecars + (motion.map { [$0] } ?? [])
    }

    /// True when the primary is a RAW file (no display master existed in the source group).
    public var primaryIsRaw: Bool {
        AssetKind.classify(pathExtension: primary.pathExtension) == .raw
    }

    /// Derived kind: a video primary ⇒ `.video`; a still primary with a motion
    /// companion ⇒ `.livePhoto`; otherwise `.image`. Single source of truth for
    /// what the importer stamps on the resulting `Asset`.
    public var mediaType: MediaType {
        if AssetKind.classify(pathExtension: primary.pathExtension) == .video { return .video }
        return motion != nil ? .livePhoto : .image
    }
}
