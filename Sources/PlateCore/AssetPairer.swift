import Foundation

public enum AssetPairer {
    /// Group files by (parent directory, lowercased basename without extension).
    /// Same-dir same-basename only — no cross-directory pairing.
    ///
    /// Within each group the primary is chosen by preference:
    ///   HEIC/HEIF/HIF > JPEG > PNG > TIFF > (first RAW if no master exists)
    ///
    /// Unknown extensions are dropped. Groups containing only sidecars (no primary
    /// and no RAW) are dropped.
    public static func pair(files: [URL]) -> [AssetPair] {
        struct GroupKey: Hashable {
            let directory: String
            let basename: String
        }
        var groups: [GroupKey: [URL]] = [:]
        for file in files {
            let key = GroupKey(
                directory: file.deletingLastPathComponent().standardizedFileURL.path,
                basename: file.deletingPathExtension().lastPathComponent.lowercased()
            )
            groups[key, default: []].append(file)
        }

        let orderedKeys = groups.keys.sorted {
            $0.directory == $1.directory ? $0.basename < $1.basename : $0.directory < $1.directory
        }

        var pairs: [AssetPair] = []
        for key in orderedKeys {
            if let pair = makePair(from: groups[key]!) {
                pairs.append(pair)
            }
        }
        return pairs
    }

    private static func makePair(from files: [URL]) -> AssetPair? {
        guard !files.isEmpty else { return nil }

        var displayMasters: [URL] = []
        var raws: [URL] = []
        var sidecars: [URL] = []
        for f in files {
            switch AssetKind.classify(pathExtension: f.pathExtension) {
            case .displayMaster: displayMasters.append(f)
            case .raw: raws.append(f)
            case .sidecar: sidecars.append(f)
            case .unknown: continue
            }
        }

        let primary: URL
        if let master = pickPreferredMaster(displayMasters) {
            primary = master
            displayMasters.removeAll { $0 == master }
        } else if !raws.isEmpty {
            // RAW-only group: promote the first RAW to primary; UI will surface the
            // embedded preview via ImageIO. Remaining RAWs stay as siblings.
            primary = raws.removeFirst()
        } else {
            return nil
        }

        // Rare case: multiple display masters in one group (e.g. IMG.JPG + IMG.PNG).
        // Demote the non-preferred ones to sidecars so they still get copied along.
        let extraSidecars = sidecars + displayMasters
        return AssetPair(primary: primary, raws: raws, sidecars: extraSidecars)
    }

    private static let masterPriority: [String] = [
        "heic", "heif", "hif", "jpg", "jpeg", "png", "tif", "tiff"
    ]

    private static func pickPreferredMaster(_ candidates: [URL]) -> URL? {
        for ext in masterPriority {
            if let match = candidates.first(where: { $0.pathExtension.lowercased() == ext }) {
                return match
            }
        }
        return candidates.first
    }
}
