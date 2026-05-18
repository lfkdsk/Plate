import Foundation

/// A logical asset prior to library import — a group of source files sharing a basename.
public struct AssetPair: Equatable {
    public var primary: URL
    public var raws: [URL]
    public var sidecars: [URL]

    public init(primary: URL, raws: [URL] = [], sidecars: [URL] = []) {
        self.primary = primary
        self.raws = raws
        self.sidecars = sidecars
    }

    public var allFiles: [URL] {
        [primary] + raws + sidecars
    }

    /// True when the primary is a RAW file (no display master existed in the source group).
    public var primaryIsRaw: Bool {
        AssetKind.classify(pathExtension: primary.pathExtension) == .raw
    }
}
