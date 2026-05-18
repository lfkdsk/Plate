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
}
