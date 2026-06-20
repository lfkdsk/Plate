import XCTest
@testable import PlateCore

final class AssetPairerTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(fileURLWithPath: s) }

    func testSameDirSameBasenameGroups() {
        let pairs = AssetPairer.pair(files: [
            url("/photos/2024-05-12/IMG_0001.JPG"),
            url("/photos/2024-05-12/IMG_0001.3FR"),
            url("/photos/2024-05-12/IMG_0002.JPG"),
        ])
        XCTAssertEqual(pairs.count, 2)
        let first = pairs[0]
        XCTAssertEqual(first.primary.lastPathComponent, "IMG_0001.JPG")
        XCTAssertEqual(first.raws.map(\.lastPathComponent), ["IMG_0001.3FR"])
    }

    func testCrossDirSameBasenameDoesNotGroup() {
        let pairs = AssetPairer.pair(files: [
            url("/photos/A/IMG_0001.JPG"),
            url("/photos/B/IMG_0001.3FR"),
        ])
        // Two separate pairs — one JPEG-only and one RAW-only (with embedded preview).
        XCTAssertEqual(pairs.count, 2)
    }

    func testHeifPreferredOverJpegAsPrimary() {
        let pairs = AssetPairer.pair(files: [
            url("/x/IMG.JPG"),
            url("/x/IMG.HIF"),
            url("/x/IMG.3FR"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.lastPathComponent, "IMG.HIF")
        // JPG demoted into sidecars (rare case, multiple masters in one group).
        let sidecarExts = pairs[0].sidecars.map { $0.pathExtension.lowercased() }
        XCTAssertTrue(sidecarExts.contains("jpg"))
        XCTAssertEqual(pairs[0].raws.map(\.lastPathComponent), ["IMG.3FR"])
    }

    func testRawOnlyGroupPromotedToPrimary() {
        let pairs = AssetPairer.pair(files: [
            url("/x/IMG.3FR"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].primaryIsRaw)
        XCTAssertTrue(pairs[0].raws.isEmpty)
    }

    func testCaseInsensitiveBasenameMatching() {
        let pairs = AssetPairer.pair(files: [
            url("/x/IMG_0001.JPG"),
            url("/x/img_0001.3fr"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].raws.count, 1)
    }

    func testUnknownExtensionsIgnored() {
        let pairs = AssetPairer.pair(files: [
            url("/x/IMG.JPG"),
            url("/x/IMG.txt"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sidecars.count, 0)
    }

    func testXmpSidecarStaysWithGroup() {
        let pairs = AssetPairer.pair(files: [
            url("/x/IMG.JPG"),
            url("/x/IMG.3FR"),
            url("/x/IMG.xmp"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sidecars.map(\.lastPathComponent), ["IMG.xmp"])
    }

    /// Every display-master + RAW combination sharing a basename folds into one
    /// asset, regardless of which base type the master is (JPEG / HEIF / PNG /
    /// TIFF). The display master is always the primary; the RAW hangs off it.
    /// This is the RAW+JPEG / RAW+HEIF shooter's expectation at import time.
    func testDisplayMasterPlusRawFoldsForAllBaseTypes() {
        let cases: [(master: String, raw: String)] = [
            ("IMG.JPG",  "IMG.CR3"),   // Canon RAW + JPEG
            ("IMG.jpeg", "IMG.NEF"),   // Nikon
            ("IMG.HEIC", "IMG.ARW"),   // Sony RAW + HEIF
            ("IMG.hif",  "IMG.3FR"),   // Hasselblad RAW + HEIF
            ("IMG.TIF",  "IMG.dng"),   // TIFF + DNG
            ("IMG.png",  "IMG.rw2"),   // PNG + Panasonic RAW
        ]
        for c in cases {
            let dir = "/card/\(UUID().uuidString)"
            let pairs = AssetPairer.pair(files: [
                url("\(dir)/\(c.master)"),
                url("\(dir)/\(c.raw)"),
            ])
            XCTAssertEqual(pairs.count, 1, "\(c.master)+\(c.raw) should fold to one asset")
            XCTAssertEqual(pairs.first?.primary.lastPathComponent, c.master,
                           "display master should be primary for \(c.master)+\(c.raw)")
            XCTAssertEqual(pairs.first?.raws.map { $0.lastPathComponent }, [c.raw])
            XCTAssertFalse(pairs.first?.primaryIsRaw ?? true)
        }
    }

    // MARK: - Video & Live Photo

    /// A movie sharing a still's basename is that still's Live Photo motion —
    /// one asset, still is primary, movie is `motion`, kind is `.livePhoto`.
    func testStillPlusMovieIsLivePhoto() {
        let pairs = AssetPairer.pair(files: [
            url("/dcim/IMG_0007.HEIC"),
            url("/dcim/IMG_0007.MOV"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.lastPathComponent, "IMG_0007.HEIC")
        XCTAssertEqual(pairs[0].motion?.lastPathComponent, "IMG_0007.MOV")
        XCTAssertEqual(pairs[0].mediaType, .livePhoto)
        // The movie is the motion companion, not a sidecar.
        XCTAssertTrue(pairs[0].sidecars.isEmpty)
    }

    /// A movie with no same-basename still is a standalone video: the movie is
    /// the primary and the kind is `.video`.
    func testVideoOnlyGroupBecomesVideo() {
        let pairs = AssetPairer.pair(files: [
            url("/dcim/CLIP_0001.mp4"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.lastPathComponent, "CLIP_0001.mp4")
        XCTAssertNil(pairs[0].motion)
        XCTAssertEqual(pairs[0].mediaType, .video)
    }

    /// Still + RAW + movie (a Live Photo shot also writing RAW): still is
    /// primary, RAW hangs off `.raws`, movie is the motion companion.
    func testStillPlusRawPlusMovieKeepsAllThree() {
        let pairs = AssetPairer.pair(files: [
            url("/dcim/IMG_9.HEIC"),
            url("/dcim/IMG_9.DNG"),
            url("/dcim/IMG_9.MOV"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.lastPathComponent, "IMG_9.HEIC")
        XCTAssertEqual(pairs[0].raws.map(\.lastPathComponent), ["IMG_9.DNG"])
        XCTAssertEqual(pairs[0].motion?.lastPathComponent, "IMG_9.MOV")
        XCTAssertEqual(pairs[0].mediaType, .livePhoto)
    }

    /// A separate clip and a separate photo (different basenames) stay two
    /// assets — one video, one image — never folded.
    func testDistinctVideoAndPhotoStaySeparate() {
        let pairs = AssetPairer.pair(files: [
            url("/dcim/A.JPG"),
            url("/dcim/B.MOV"),
        ])
        XCTAssertEqual(pairs.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: pairs.map { ($0.primary.lastPathComponent, $0) })
        XCTAssertEqual(byName["A.JPG"]?.mediaType, .image)
        XCTAssertEqual(byName["B.MOV"]?.mediaType, .video)
    }

    /// When one shot has two display masters AND a RAW (e.g. a camera writing
    /// JPEG + HEIF, plus the RAW), it still collapses to a single asset: the
    /// preferred master (HEIF) is primary, the RAW folds in, and the secondary
    /// master is preserved as a tagalong sidecar — never silently dropped, so
    /// import is lossless and export-with-RAW still carries it out.
    func testMultipleDisplayMastersKeepSecondaryAsSidecar() {
        let dir = "/card/multi"
        let pairs = AssetPairer.pair(files: [
            url("\(dir)/IMG.JPG"),
            url("\(dir)/IMG.HEIC"),
            url("\(dir)/IMG.3FR"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.lastPathComponent, "IMG.HEIC")
        XCTAssertEqual(pairs[0].raws.map { $0.lastPathComponent }, ["IMG.3FR"])
        // The JPEG isn't lost — it rides along as a sidecar of the same asset.
        XCTAssertEqual(pairs[0].sidecars.map { $0.lastPathComponent }, ["IMG.JPG"])
    }
}
