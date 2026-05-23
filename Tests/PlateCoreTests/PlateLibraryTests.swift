import XCTest
import ImageIO
import CoreGraphics
@testable import PlateCore

final class PlateLibraryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCreateAndOpenRoundtrip() throws {
        let libURL = tempRoot.appendingPathComponent("MyLib.plate")
        let created = try PlateLibrary.create(at: libURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.originalsDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.thumbsDir.path))

        let reopened = try PlateLibrary.open(at: libURL)
        XCTAssertEqual(reopened.assetCount, 0)
        XCTAssertEqual(reopened.assets.count, 0)
    }

    func testCreateFailsWhenPathExists() throws {
        let libURL = tempRoot.appendingPathComponent("Lib.plate")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PlateLibrary.create(at: libURL))
    }

    func testOpenFailsOnPlainDirectory() throws {
        let dir = tempRoot.appendingPathComponent("not-a-lib")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PlateLibrary.open(at: dir))
    }

    func testAlbumReorderPersists() throws {
        let libURL = tempRoot.appendingPathComponent("AlbumOrder.plate")
        let lib = try PlateLibrary.create(at: libURL)

        // New albums append in creation order (position 0, 1, 2).
        let a = try lib.createAlbum(name: "Alpha")
        let b = try lib.createAlbum(name: "Bravo")
        let c = try lib.createAlbum(name: "Charlie")
        XCTAssertEqual(lib.albums.map(\.name), ["Alpha", "Bravo", "Charlie"])

        // Reorder to Charlie, Alpha, Bravo.
        try lib.reorderAlbums(orderedIDs: [c, a, b])
        XCTAssertEqual(lib.albums.map(\.name), ["Charlie", "Alpha", "Bravo"])

        // Order survives a close + reopen (persisted, not just in-memory).
        let reopened = try PlateLibrary.open(at: libURL)
        XCTAssertEqual(reopened.albums.map(\.name), ["Charlie", "Alpha", "Bravo"])
    }

    func testExistingContentHashesFlagsImported() throws {
        let libURL = tempRoot.appendingPathComponent("Dedup.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let card = tempRoot.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let imgA = card.appendingPathComponent("A.JPG")
        let imgB = card.appendingPathComponent("B.JPG")
        try Self.writeTestJPEG(to: imgA, width: 64, height: 48)
        try Self.writeTestJPEG(to: imgB, width: 80, height: 60)   // different bytes

        // Import only A; B stays on the "card".
        let result = try lib.importPairs([AssetPair(primary: imgA)], thumbnailPixel: 64)
        XCTAssertEqual(result.imported.count, 1)

        // The picker's pre-flag: A is already imported, B is new.
        let existing = lib.existingContentHashes()
        XCTAssertEqual(existing.count, 1)
        XCTAssertTrue(existing.contains(try lib.contentHash(of: imgA)))
        XCTAssertFalse(existing.contains(try lib.contentHash(of: imgB)))
    }

    func testExportCopiesMasterAndAvoidsCollision() throws {
        let libURL = tempRoot.appendingPathComponent("Export.plate")
        let lib = try PlateLibrary.create(at: libURL)
        let srcDir = tempRoot.appendingPathComponent("esrc")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let jpeg = srcDir.appendingPathComponent("IMG_1.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 100, height: 80)
        let asset = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 64).imported[0]

        let dest = tempRoot.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let r1 = try lib.exportAssets([asset], to: dest)
        XCTAssertEqual(r1.exported, 1)
        XCTAssertTrue(r1.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("IMG_1.JPG").path))

        // Re-exporting the same asset must not overwrite — it makes a second copy.
        let r2 = try lib.exportAssets([asset], to: dest)
        XCTAssertEqual(r2.exported, 1)
        let jpegs = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            .filter { $0.lowercased().hasSuffix(".jpg") }
        XCTAssertEqual(jpegs.count, 2)
    }

    func testImportJPEGGeneratesThumbnailAndPersists() throws {
        let libURL = tempRoot.appendingPathComponent("ImportLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let sourceDir = tempRoot.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let jpegURL = sourceDir.appendingPathComponent("IMG_0001.JPG")
        try Self.writeTestJPEG(to: jpegURL, width: 200, height: 150)

        let pair = AssetPair(primary: jpegURL)
        let result = try lib.importPairs([pair], thumbnailPixel: 128)
        XCTAssertEqual(result.imported.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let asset = result.imported[0]

        // Primary copied into Originals/<yyyy>/<yyyy-MM-dd>/
        let primaryAbs = lib.absoluteURL(forRelative: asset.primary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryAbs.path))
        XCTAssertTrue(asset.primary.hasPrefix("Originals/"))

        // Dimensions captured during import (needed for justified-grid layout).
        XCTAssertEqual(asset.pixelWidth, 200)
        XCTAssertEqual(asset.pixelHeight, 150)
        XCTAssertEqual(asset.aspectRatio, 200.0 / 150.0, accuracy: 0.001)

        // Thumbnail written
        XCTAssertNotNil(asset.thumbnail)
        let thumbAbs = lib.absoluteURL(forRelative: asset.thumbnail!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbAbs.path))

        // Manifest persisted
        let reopened = try PlateLibrary.open(at: libURL)
        XCTAssertEqual(reopened.manifest.assets.count, 1)
        XCTAssertEqual(reopened.manifest.assets[0].id, asset.id)
    }

    func testImportCollisionRenamesPrimaryAndRaw() throws {
        let libURL = tempRoot.appendingPathComponent("CollLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let srcA = tempRoot.appendingPathComponent("a")
        let srcB = tempRoot.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: srcA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcB, withIntermediateDirectories: true)

        // Different colors → different bytes → different SHA-256 → both import
        // (otherwise dedup would catch the second pair as identical).
        let jpegA = srcA.appendingPathComponent("IMG.JPG")
        let rawA = srcA.appendingPathComponent("IMG.3FR")
        try Self.writeTestJPEG(to: jpegA, width: 80, height: 60,
                               color: CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1.0))
        try Data("FAKE-RAW-A".utf8).write(to: rawA)

        let jpegB = srcB.appendingPathComponent("IMG.JPG")
        let rawB = srcB.appendingPathComponent("IMG.3FR")
        try Self.writeTestJPEG(to: jpegB, width: 80, height: 60,
                               color: CGColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 1.0))
        try Data("FAKE-RAW-B".utf8).write(to: rawB)

        // Force same capture date so both target the same directory.
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: jpegA.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: jpegB.path)

        let pairA = AssetPair(primary: jpegA, raws: [rawA])
        let pairB = AssetPair(primary: jpegB, raws: [rawB])
        let result = try lib.importPairs([pairA, pairB], thumbnailPixel: 64)
        XCTAssertEqual(result.imported.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
        let imported = result.imported

        // The second pair's primary must NOT overwrite the first.
        let p1 = lib.absoluteURL(forRelative: imported[0].primary)
        let p2 = lib.absoluteURL(forRelative: imported[1].primary)
        XCTAssertNotEqual(p1.path, p2.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2.path))

        // Second RAW must follow its primary's renamed basename, not collide.
        let r1 = lib.absoluteURL(forRelative: imported[0].raws[0])
        let r2 = lib.absoluteURL(forRelative: imported[1].raws[0])
        XCTAssertNotEqual(r1.path, r2.path)
        XCTAssertEqual(try Data(contentsOf: r1), Data("FAKE-RAW-A".utf8))
        XCTAssertEqual(try Data(contentsOf: r2), Data("FAKE-RAW-B".utf8))
    }

    func testReimportingSameBytesIsDeduped() throws {
        let libURL = tempRoot.appendingPathComponent("DedupLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 50, height: 50)

        // First import: success.
        let first = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32)
        XCTAssertEqual(first.imported.count, 1)
        XCTAssertTrue(first.duplicates.isEmpty)

        // Same bytes, different basename → SHA-256 matches → dedup'd.
        let twin = src.appendingPathComponent("COPY.JPG")
        try FileManager.default.copyItem(at: jpeg, to: twin)
        let second = try lib.importPairs([AssetPair(primary: twin)], thumbnailPixel: 32)
        XCTAssertEqual(second.imported.count, 0)
        XCTAssertEqual(second.duplicates.count, 1)
        XCTAssertEqual(second.duplicates.first?.existing.id, first.imported.first?.id)
    }

    // MARK: - Sidebar features (v3 schema)

    func testFavoriteToggle() throws {
        let libURL = tempRoot.appendingPathComponent("FavLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src-fav")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 64, height: 64)

        let imported = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32).imported
        XCTAssertEqual(imported.count, 1)
        let asset = imported[0]
        XCTAssertFalse(asset.isFavorite)
        XCTAssertTrue(lib.favoriteAssets.isEmpty)

        // Flip on → appears in favorites + re-read asset reflects the flag.
        try lib.setFavorite(asset, isFavorite: true)
        let favs = lib.favoriteAssets
        XCTAssertEqual(favs.count, 1)
        XCTAssertEqual(favs.first?.id, asset.id)
        XCTAssertTrue(favs.first?.isFavorite ?? false)

        // Flip off → gone from favorites again.
        try lib.setFavorite(asset, isFavorite: false)
        XCTAssertTrue(lib.favoriteAssets.isEmpty)
        let after = lib.assets.first { $0.id == asset.id }
        XCTAssertNotNil(after)
        XCTAssertFalse(after?.isFavorite ?? true)
    }

    func testSoftDeletePreservesFiles() throws {
        let libURL = tempRoot.appendingPathComponent("SoftDelLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src-soft")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 64, height: 64)

        let asset = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32).imported[0]
        let primaryPath = lib.absoluteURL(forRelative: asset.primary).path

        try lib.deleteAssets([asset])

        // Files stay on disk under soft delete.
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryPath))

        // Main `assets` list excludes it; Recently Deleted contains it with a stamp.
        XCTAssertFalse(lib.assets.contains { $0.id == asset.id })
        let trashed = lib.recentlyDeletedAssets
        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(trashed.first?.id, asset.id)
        XCTAssertNotNil(trashed.first?.deletedAt)
    }

    func testRestoreFromTrash() throws {
        let libURL = tempRoot.appendingPathComponent("RestoreLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src-rest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 64, height: 64)

        let asset = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32).imported[0]
        try lib.deleteAssets([asset])
        XCTAssertEqual(lib.recentlyDeletedAssets.count, 1)
        XCTAssertFalse(lib.assets.contains { $0.id == asset.id })

        try lib.restoreAssets([asset])
        XCTAssertTrue(lib.recentlyDeletedAssets.isEmpty)
        XCTAssertTrue(lib.assets.contains { $0.id == asset.id })
        let restored = lib.assets.first { $0.id == asset.id }
        XCTAssertNil(restored?.deletedAt)
    }

    func testPermanentlyDeleteRemovesFiles() throws {
        let libURL = tempRoot.appendingPathComponent("PermDelLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src-perm")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 64, height: 64)

        let asset = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32).imported[0]
        let primaryPath = lib.absoluteURL(forRelative: asset.primary).path
        let thumbPath = asset.thumbnail.map { lib.absoluteURL(forRelative: $0).path }

        try lib.deleteAssets([asset])
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryPath))

        try lib.permanentlyDeleteAssets([asset])
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryPath))
        if let thumbPath = thumbPath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: thumbPath))
        }
        // Row is gone — neither bucket should still show it.
        XCTAssertTrue(lib.recentlyDeletedAssets.isEmpty)
        XCTAssertFalse(lib.assets.contains { $0.id == asset.id })
    }

    func testCreateAlbumAndAddAssets() throws {
        let libURL = tempRoot.appendingPathComponent("AlbumLib.plate")
        let lib = try PlateLibrary.create(at: libURL)

        let src = tempRoot.appendingPathComponent("src-alb")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = src.appendingPathComponent("IMG.JPG")
        try Self.writeTestJPEG(to: jpeg, width: 64, height: 64)
        let asset = try lib.importPairs([AssetPair(primary: jpeg)], thumbnailPixel: 32).imported[0]

        let albumID = try lib.createAlbum(name: "Trip")
        try lib.addAssets([asset], toAlbum: albumID)
        // Duplicate add is a no-op (INSERT OR IGNORE).
        try lib.addAssets([asset], toAlbum: albumID)

        let albums = lib.albums
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.name, "Trip")
        XCTAssertEqual(albums.first?.assetCount, 1)

        let inAlbum = lib.assetsInAlbum(id: albumID)
        XCTAssertEqual(inAlbum.count, 1)
        XCTAssertEqual(inAlbum.first?.id, asset.id)

        try lib.renameAlbum(id: albumID, to: "Vacation")
        XCTAssertEqual(lib.albums.first?.name, "Vacation")

        // Sanity check: soft-deleted members shouldn't count toward asset_count
        // and shouldn't appear in assetsInAlbum.
        try lib.deleteAssets([asset])
        XCTAssertEqual(lib.albums.first?.assetCount, 0)
        XCTAssertTrue(lib.assetsInAlbum(id: albumID).isEmpty)
        try lib.restoreAssets([asset])
        XCTAssertEqual(lib.albums.first?.assetCount, 1)

        // Delete album → membership rows cascade away. Assets themselves survive.
        try lib.deleteAlbum(id: albumID)
        XCTAssertTrue(lib.albums.isEmpty)
        XCTAssertTrue(lib.assetsInAlbum(id: albumID).isEmpty)
        XCTAssertTrue(lib.assets.contains { $0.id == asset.id })
    }

    /// Open a freshly-created library twice and confirm the v3 columns survive
    /// the round-trip — guards against the migration accidentally leaving the
    /// `is_favorite`/`deleted_at` columns missing on existing rows.
    func testV3RoundtripPreservesFavoriteAndDeletedState() throws {
        let libURL = tempRoot.appendingPathComponent("V3Lib.plate")
        do {
            let lib = try PlateLibrary.create(at: libURL)
            let src = tempRoot.appendingPathComponent("src-v3")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let a = src.appendingPathComponent("A.JPG")
            let b = src.appendingPathComponent("B.JPG")
            try Self.writeTestJPEG(to: a, width: 64, height: 64,
                                   color: CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0))
            try Self.writeTestJPEG(to: b, width: 64, height: 64,
                                   color: CGColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1.0))
            let imported = try lib.importPairs([AssetPair(primary: a), AssetPair(primary: b)],
                                               thumbnailPixel: 32).imported
            try lib.setFavorite(imported[0], isFavorite: true)
            try lib.deleteAssets([imported[1]])
        }
        let reopened = try PlateLibrary.open(at: libURL)
        XCTAssertEqual(reopened.favoriteAssets.count, 1)
        XCTAssertEqual(reopened.recentlyDeletedAssets.count, 1)
        XCTAssertEqual(reopened.assets.count, 1)
    }

    // MARK: - Helpers

    /// Write a tiny solid-color JPEG via ImageIO so tests don't need fixture files.
    static func writeTestJPEG(to url: URL,
                              width: Int,
                              height: Int,
                              color: CGColor = CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1.0)) throws
    {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "PlateTests", code: 1)
        }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "PlateTests", code: 2)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "PlateTests", code: 3)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "PlateTests", code: 4)
        }
    }
}
