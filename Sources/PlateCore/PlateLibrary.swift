import Foundation
import CryptoKit

public enum PlateLibraryError: Error, CustomStringConvertible {
    case alreadyExists(URL)
    case notALibrary(URL)
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .alreadyExists(let u): return "Path already exists: \(u.path)"
        case .notALibrary(let u): return "Not a Plate library: \(u.path)"
        case .unsupportedVersion(let v): return "Unsupported library version: \(v)"
        }
    }
}

/// A `.plate` library bundle on disk. Layout:
///
///     Library.plate/
///       library.db                          ← SQLite (new format)
///       manifest.json.bak                   ← if migrated from v1 manifest format
///       Originals/<yyyy>/<yyyy-MM-dd>/<basename>.<ext>
///       Caches/thumbs/<asset-id>-<px>.jpg
///
/// Internals stay plain — opening the bundle in Finder (or `cd`'ing into it)
/// gives a normal date-organized directory tree that survives without the app.
public final class PlateLibrary {
    public let url: URL
    private let store: AssetStore

    public var originalsDir: URL { url.appendingPathComponent("Originals", isDirectory: true) }
    public var cachesDir: URL { url.appendingPathComponent("Caches", isDirectory: true) }
    public var thumbsDir: URL { cachesDir.appendingPathComponent("thumbs", isDirectory: true) }
    public var databaseURL: URL { url.appendingPathComponent("library.db") }
    /// Legacy v1 manifest path; consulted only for one-time migration on open.
    public var legacyManifestURL: URL { url.appendingPathComponent("manifest.json") }

    private init(url: URL, store: AssetStore) {
        self.url = url.standardizedFileURL
        self.store = store
    }

    // MARK: - Create / open

    public static func create(at url: URL) throws -> PlateLibrary {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL
        if fm.fileExists(atPath: standardized.path) {
            throw PlateLibraryError.alreadyExists(standardized)
        }
        try fm.createDirectory(at: standardized, withIntermediateDirectories: true)
        let originals = standardized.appendingPathComponent("Originals", isDirectory: true)
        let caches    = standardized.appendingPathComponent("Caches", isDirectory: true)
        let thumbs    = caches.appendingPathComponent("thumbs", isDirectory: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)

        let dbURL = standardized.appendingPathComponent("library.db")
        let store = try AssetStore(url: dbURL)
        return PlateLibrary(url: standardized, store: store)
    }

    public static func open(at url: URL) throws -> PlateLibrary {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL
        let dbURL = standardized.appendingPathComponent("library.db")
        let legacyManifest = standardized.appendingPathComponent("manifest.json")

        let hasDB = fm.fileExists(atPath: dbURL.path)
        let hasManifest = fm.fileExists(atPath: legacyManifest.path)
        guard hasDB || hasManifest else {
            throw PlateLibraryError.notALibrary(standardized)
        }

        let store = try AssetStore(url: dbURL)
        let lib = PlateLibrary(url: standardized, store: store)

        // One-time migration from the v1 manifest.json. We only migrate when the
        // DB is empty — if it has rows, the manifest is stale and shouldn't
        // re-flood the table. Manifest gets renamed to .bak after a successful
        // migration so we don't try again next launch.
        if hasManifest, try lib.store.count() == 0 {
            try lib.migrateLegacyManifest(at: legacyManifest)
        }

        return lib
    }

    private func migrateLegacyManifest(at manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(LibraryManifest.self, from: data)
        guard legacy.version <= LibraryManifest.currentVersion else {
            throw PlateLibraryError.unsupportedVersion(legacy.version)
        }
        try store.bulkInsert(legacy.assets)
        // Keep a backup but get it out of the way so we don't re-migrate.
        let backup = manifestURL.deletingPathExtension().appendingPathExtension("json.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: manifestURL, to: backup)
    }

    // MARK: - Read

    /// Snapshot of all assets, sorted newest-first by capture date.
    /// Backwards-compat: the UI used to read `lib.manifest.assets` — provide a
    /// lightweight Manifest wrapper that pulls from the store.
    public var assets: [Asset] {
        (try? store.allAssetsCapturedDesc()) ?? []
    }

    public var manifest: LibraryManifest {
        LibraryManifest(version: LibraryManifest.currentVersion,
                        createdAt: Date(),
                        assets: assets)
    }

    public var assetCount: Int {
        (try? store.count()) ?? 0
    }

    // MARK: - Import

    public typealias ImportProgress = (_ completed: Int, _ total: Int) -> Void

    public struct ImportResult {
        public var imported: [Asset]
        public var duplicates: [(source: URL, existing: Asset)]
        public var failures: [(source: URL, error: Error)]
    }

    /// Copy each pair's files into `Originals/yyyy/yyyy-MM-dd/` and generate a
    /// thumbnail. Per-pair errors are *caught and accumulated* rather than
    /// thrown — a single unreadable file (Phocus-denoised 3FR, corrupt JPEG,
    /// etc.) shouldn't kill a whole batch. Callers inspect `result.failures`
    /// for what didn't make it. The `progress` closure is invoked after each
    /// pair (success or fail).
    @discardableResult
    public func importPairs(_ pairs: [AssetPair],
                            thumbnailPixel: Int = 512,
                            progress: ImportProgress? = nil) throws -> ImportResult
    {
        let fm = FileManager.default
        let thumbnailer = ThumbnailService()
        var imported: [Asset] = []
        var duplicates: [(URL, Asset)] = []
        var failures: [(URL, Error)] = []
        imported.reserveCapacity(pairs.count)

        let total = pairs.count
        progress?(0, total)

        for (idx, pair) in pairs.enumerated() {
            do {
                // Content-hash dedup: if the same bytes are already in the
                // library (under any name), skip this pair entirely.
                let hash = try Self.sha256Hex(of: pair.primary)
                if let existing = try store.findAsset(byContentHash: hash) {
                    duplicates.append((pair.primary, existing))
                    progress?(idx + 1, total)
                    continue
                }

                let meta = ExifReader.readMetadata(for: pair.primary)
                let dateSubpath = Self.dateDirectory(for: meta.capturedAt ?? Date())
                let targetDir = originalsDir.appendingPathComponent(dateSubpath, isDirectory: true)
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

                let primaryDest = try copyAvoidingCollision(pair.primary, into: targetDir)
                let finalBasename = primaryDest.deletingPathExtension().lastPathComponent

                var copiedRaws: [URL] = []
                for raw in pair.raws {
                    let target = targetDir.appendingPathComponent("\(finalBasename).\(raw.pathExtension)")
                    try Self.copyOverwriting(raw, to: target)
                    copiedRaws.append(target)
                }
                var copiedSidecars: [URL] = []
                for side in pair.sidecars {
                    let target = targetDir.appendingPathComponent("\(finalBasename).\(side.pathExtension)")
                    try Self.copyOverwriting(side, to: target)
                    copiedSidecars.append(target)
                }

                let assetID = UUID()
                let thumbURL = thumbsDir.appendingPathComponent("\(assetID.uuidString)-\(thumbnailPixel).jpg")

                // Thumbnail failure is non-fatal: keep the asset visible (no
                // preview) so the original is still searchable / openable.
                let thumbnailPath: String?
                do {
                    try thumbnailer.generate(from: primaryDest, maxPixel: thumbnailPixel, to: thumbURL)
                    thumbnailPath = relativePath(of: thumbURL)
                } catch {
                    thumbnailPath = nil
                }

                let asset = Asset(
                    id: assetID,
                    primary: relativePath(of: primaryDest),
                    raws: copiedRaws.map(relativePath(of:)),
                    sidecars: copiedSidecars.map(relativePath(of:)),
                    capturedAt: meta.capturedAt,
                    pixelWidth: meta.pixelWidth,
                    pixelHeight: meta.pixelHeight,
                    thumbnail: thumbnailPath,
                    contentHash: hash
                )
                try store.insert(asset)
                imported.append(asset)
            } catch {
                // Fatal per-pair errors (copy failed / DB insert failed) — log
                // and keep going. The whole batch shouldn't die for one bad file.
                failures.append((pair.primary, error))
            }

            progress?(idx + 1, total)
        }

        return ImportResult(imported: imported, duplicates: duplicates, failures: failures)
    }

    /// Streaming SHA-256 of a file. 1MB buffer keeps memory bounded even for
    /// huge HEIC / RAW files; reading via `FileHandle.readData(ofLength:)`
    /// works on all macOS 10.15.x deployments (the `read(upToCount:)` variant
    /// is 10.15.4+).
    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        autoreleasepool {
            while true {
                let chunk = handle.readData(ofLength: 1 << 20)   // 1MB
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        }
        let digest = hasher.finalize()
        return digest.reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    /// SHA-256 hex of a file's bytes — the same digest used for import dedup.
    /// Lets the import picker test a candidate against the library before copying.
    public func contentHash(of url: URL) throws -> String {
        try Self.sha256Hex(of: url)
    }

    /// Snapshot of every content hash already in the library. Combine with
    /// `contentHash(of:)` for O(1) "already imported?" checks while scanning a
    /// camera / SD card.
    public func existingContentHashes() -> Set<String> {
        (try? store.allContentHashes()) ?? []
    }

    public struct ExportResult {
        public var exported: Int
        public var failures: [(asset: Asset, error: Error)]
    }

    /// Copy assets' files out of the library into `destination`. The display
    /// master always goes; `includeRaws` / `includeSidecars` add the RAW
    /// companions and XMP/AAE sidecars. Companions keep the (possibly
    /// collision-renamed) master's basename so the exported group re-pairs
    /// cleanly on a future import. Existing files in `destination` are never
    /// overwritten — colliding names get a numeric suffix. Per-asset failures
    /// are accumulated, not thrown, so one unreadable file doesn't abort the set.
    @discardableResult
    public func exportAssets(_ assets: [Asset],
                             to destination: URL,
                             includeRaws: Bool = true,
                             includeSidecars: Bool = true) throws -> ExportResult {
        var exported = 0
        var failures: [(Asset, Error)] = []
        for asset in assets {
            do {
                let masterDest = try copyAvoidingCollision(
                    absoluteURL(forRelative: asset.primary), into: destination)
                let base = masterDest.deletingPathExtension().lastPathComponent
                if includeRaws {
                    for raw in asset.raws {
                        let src = absoluteURL(forRelative: raw)
                        let target = destination.appendingPathComponent("\(base).\(src.pathExtension)")
                        try Self.copyOverwriting(src, to: target)
                    }
                }
                if includeSidecars {
                    for side in asset.sidecars {
                        let src = absoluteURL(forRelative: side)
                        let target = destination.appendingPathComponent("\(base).\(src.pathExtension)")
                        try Self.copyOverwriting(src, to: target)
                    }
                }
                exported += 1
            } catch {
                failures.append((asset, error))
            }
        }
        return ExportResult(exported: exported, failures: failures)
    }

    /// Resolve a stored relative path back to an absolute URL inside the bundle.
    public func absoluteURL(forRelative path: String) -> URL {
        url.appendingPathComponent(path)
    }

    // MARK: - Rebuild

    public struct RebuildResult {
        public var rebuilt: Int
        public var failures: [(asset: Asset, error: Error)]
    }

    /// Re-derive every asset's metadata + thumbnail + content hash from its
    /// primary file on disk. Doesn't move or copy any originals; only updates
    /// DB rows and rewrites thumbnail JPEGs under `Caches/thumbs/`.
    ///
    /// Preserved as-is: favorite state, album membership, soft-delete state,
    /// file paths (primary/raws/sidecars). Refreshed: capturedAt, pixelWidth,
    /// pixelHeight, thumbnail relative path, contentHash.
    ///
    /// Soft-deleted rows are rebuilt too — if the user restores from Recently
    /// Deleted later, the thumbnail will already be fresh. Per-asset errors
    /// (missing primary file, unreadable image) are accumulated into
    /// `RebuildResult.failures` rather than thrown; the batch keeps going.
    @discardableResult
    public func rebuildAllAssets(thumbnailPixel: Int = 512,
                                 progress: ImportProgress? = nil) throws -> RebuildResult
    {
        let fm = FileManager.default
        let thumbnailer = ThumbnailService()
        let all = try store.allAssetsIncludingDeleted()
        let total = all.count
        progress?(0, total)

        var rebuilt = 0
        var failures: [(Asset, Error)] = []

        for (idx, asset) in all.enumerated() {
            do {
                let primaryURL = absoluteURL(forRelative: asset.primary)
                guard fm.fileExists(atPath: primaryURL.path) else {
                    throw NSError(domain: "PlateLibrary.Rebuild", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Primary file missing on disk: \(asset.primary)"
                    ])
                }

                let meta = ExifReader.readMetadata(for: primaryURL)
                let hash = try Self.sha256Hex(of: primaryURL)

                let thumbURL = thumbsDir.appendingPathComponent(
                    "\(asset.id.uuidString)-\(thumbnailPixel).jpg"
                )
                // Wipe any stale thumbnail first so a generator failure leaves
                // the row honestly empty rather than pointing at outdated bytes.
                try? fm.removeItem(at: thumbURL)

                let thumbnailPath: String?
                do {
                    try thumbnailer.generate(from: primaryURL,
                                             maxPixel: thumbnailPixel,
                                             to: thumbURL)
                    thumbnailPath = relativePath(of: thumbURL)
                } catch {
                    thumbnailPath = nil
                }

                // For fields where re-extraction returned nil (e.g. EXIF
                // missing), preserve what was already on the row rather than
                // blowing away good data. Hash always wins — it's the canonical
                // identity of the bytes and should be authoritative.
                try store.updateAssetMetadata(
                    id: asset.id,
                    capturedAt: meta.capturedAt ?? asset.capturedAt,
                    pixelWidth: meta.pixelWidth ?? asset.pixelWidth,
                    pixelHeight: meta.pixelHeight ?? asset.pixelHeight,
                    thumbnail: thumbnailPath,
                    contentHash: hash
                )
                rebuilt += 1
            } catch {
                failures.append((asset, error))
            }
            progress?(idx + 1, total)
        }

        return RebuildResult(rebuilt: rebuilt, failures: failures)
    }

    // MARK: - Delete

    /// "Trash" a batch of assets — soft delete only. Files stay on disk, rows
    /// stay in the table; only `deleted_at` is stamped so they vanish from the
    /// main grid and surface in Recently Deleted. Restorable until the user
    /// empties the trash via `permanentlyDeleteAssets(_:)`.
    public func deleteAssets(_ assetsToDelete: [Asset]) throws {
        try store.softDeleteAssets(ids: assetsToDelete.map(\.id))
    }

    /// Empty-the-trash primitive: removes primary + RAW companions + sidecars
    /// + thumbnail from disk, then the rows from the database in a
    /// transaction. File removal errors are non-fatal (file already missing is
    /// fine); only a DB transaction failure throws.
    public func permanentlyDeleteAssets(_ assetsToDelete: [Asset]) throws {
        let fm = FileManager.default
        for asset in assetsToDelete {
            try? fm.removeItem(at: absoluteURL(forRelative: asset.primary))
            for raw in asset.raws {
                try? fm.removeItem(at: absoluteURL(forRelative: raw))
            }
            for side in asset.sidecars {
                try? fm.removeItem(at: absoluteURL(forRelative: side))
            }
            if let thumb = asset.thumbnail {
                try? fm.removeItem(at: absoluteURL(forRelative: thumb))
            }
        }
        try store.permanentlyDeleteAssets(ids: assetsToDelete.map(\.id))
    }

    /// Lift soft-deleted assets back into the main grid.
    public func restoreAssets(_ assetsToRestore: [Asset]) throws {
        try store.restoreAssets(ids: assetsToRestore.map(\.id))
    }

    // MARK: - Favorites

    /// Flip the favorite flag on an asset. Convenience wrapper around the
    /// store-level setter — the sidebar's heart toggle hits this directly.
    public func setFavorite(_ asset: Asset, isFavorite: Bool) throws {
        try store.setFavorite(assetID: asset.id, isFavorite: isFavorite)
    }

    public var favoriteAssets: [Asset] {
        (try? store.favoriteAssetsCapturedDesc()) ?? []
    }

    public var recentlyDeletedAssets: [Asset] {
        (try? store.recentlyDeletedAssetsCapturedDesc()) ?? []
    }

    // MARK: - Albums

    @discardableResult
    public func createAlbum(name: String) throws -> UUID {
        try store.createAlbum(name: name)
    }

    public func deleteAlbum(id: UUID) throws {
        try store.deleteAlbum(id: id)
    }

    public func renameAlbum(id: UUID, to newName: String) throws {
        try store.renameAlbum(id: id, to: newName)
    }

    /// Persist a user-defined album order (sidebar drag-to-reorder). Pass every
    /// album id in the desired top-to-bottom order.
    public func reorderAlbums(orderedIDs: [UUID]) throws {
        try store.setAlbumOrder(orderedIDs)
    }

    public var albums: [(id: UUID, name: String, assetCount: Int)] {
        (try? store.listAlbums()) ?? []
    }

    public func addAssets(_ assetsToAdd: [Asset], toAlbum albumID: UUID) throws {
        try store.addAssets(ids: assetsToAdd.map(\.id), toAlbum: albumID)
    }

    public func removeAssets(_ assetsToRemove: [Asset], fromAlbum albumID: UUID) throws {
        try store.removeAssets(ids: assetsToRemove.map(\.id), fromAlbum: albumID)
    }

    public func assetsInAlbum(id albumID: UUID) -> [Asset] {
        (try? store.assetsInAlbumCapturedDesc(id: albumID)) ?? []
    }

    // MARK: - Internals

    private func relativePath(of fileURL: URL) -> String {
        let prefix = url.path + "/"
        let full = fileURL.standardizedFileURL.path
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    private func copyAvoidingCollision(_ source: URL, into targetDir: URL) throws -> URL {
        let fm = FileManager.default
        let target = targetDir.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: source, to: target)
            return target
        }
        let basename = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for i in 1...9999 {
            let candidate = targetDir.appendingPathComponent("\(basename) (\(i)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) {
                try fm.copyItem(at: source, to: candidate)
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func copyOverwriting(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
    }

    private static func dateDirectory(for date: Date) -> String {
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%04d-%02d-%02d", comps.year!, comps.year!, comps.month!, comps.day!)
    }
}
