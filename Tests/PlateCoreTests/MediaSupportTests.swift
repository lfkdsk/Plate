import XCTest
@testable import PlateCore

/// Pure-function coverage for the video / Live Photo support: classification,
/// the media-type field's decode tolerance, the HTTP Range parser the web
/// server uses for `<video>` playback, and the QuickTime GPS parser.
final class MediaSupportTests: XCTestCase {

    // MARK: - AssetKind

    func testVideoExtensionsClassifyAsVideo() {
        for ext in ["mov", "MOV", "mp4", "m4v", "webm", "3gp"] {
            XCTAssertEqual(AssetKind.classify(pathExtension: ext), .video, "\(ext) should be video")
        }
        XCTAssertEqual(AssetKind.classify(pathExtension: "jpg"), .displayMaster)
        XCTAssertEqual(AssetKind.classify(pathExtension: "3fr"), .raw)
        XCTAssertEqual(AssetKind.classify(pathExtension: "mp3"), .unknown)
    }

    func testAllSupportedExtensionsIncludesVideo() {
        let all = AssetKind.allSupportedExtensions
        XCTAssertTrue(all.contains("mov"))
        XCTAssertTrue(all.contains("mp4"))
        // Still includes the legacy stills + raw + sidecar sets.
        XCTAssertTrue(all.contains("heic"))
        XCTAssertTrue(all.contains("xmp"))
    }

    // MARK: - MediaType

    func testMediaTypeStoredValueTolerance() {
        XCTAssertEqual(MediaType(storedValue: "video"), .video)
        XCTAssertEqual(MediaType(storedValue: "livePhoto"), .livePhoto)
        XCTAssertEqual(MediaType(storedValue: "livephoto"), .livePhoto)   // case-folded
        XCTAssertEqual(MediaType(storedValue: "image"), .image)
        // Unknown / missing → image, never a throw.
        XCTAssertEqual(MediaType(storedValue: "spatial"), .image)
        XCTAssertEqual(MediaType(storedValue: nil), .image)
    }

    /// A legacy manifest.json row (schema < v6) has no mediaType key → decodes
    /// as a still with no motion / duration. Guards back-compat.
    func testAssetDecodesLegacyJSONAsImage() throws {
        let legacy = """
        { "id": "\(UUID().uuidString)", "primary": "Originals/2020/2020-01-01/IMG.JPG",
          "raws": [], "sidecars": [], "isFavorite": false }
        """.data(using: .utf8)!
        let asset = try JSONDecoder().decode(Asset.self, from: legacy)
        XCTAssertEqual(asset.mediaType, .image)
        XCTAssertNil(asset.motionPath)
        XCTAssertNil(asset.duration)
    }

    func testAssetMediaTypeRoundTripsThroughCodable() throws {
        let original = Asset(primary: "Originals/x/CLIP.MOV",
                             mediaType: .video, duration: 12.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Asset.self, from: data)
        XCTAssertEqual(decoded.mediaType, .video)
        XCTAssertEqual(decoded.duration, 12.5)
    }

    // MARK: - HTTP Range parsing (web server video playback)

    func testParseByteRangeStartEnd() {
        let r = PlateWebServer.parseByteRange("bytes=0-499", fileSize: 1000)
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 499)
        XCTAssertEqual(r?.length, 500)
    }

    func testParseByteRangeOpenEndedClampsToFile() {
        let r = PlateWebServer.parseByteRange("bytes=500-", fileSize: 1000)
        XCTAssertEqual(r?.start, 500)
        XCTAssertEqual(r?.end, 999)
        XCTAssertEqual(r?.length, 500)
    }

    func testParseByteRangeSuffix() {
        // Last 200 bytes.
        let r = PlateWebServer.parseByteRange("bytes=-200", fileSize: 1000)
        XCTAssertEqual(r?.start, 800)
        XCTAssertEqual(r?.end, 999)
        XCTAssertEqual(r?.length, 200)
    }

    func testParseByteRangeInvalidOrUnsatisfiable() {
        XCTAssertNil(PlateWebServer.parseByteRange("items=0-1", fileSize: 1000))   // wrong unit
        XCTAssertNil(PlateWebServer.parseByteRange("bytes=2000-3000", fileSize: 1000)) // past EOF
        XCTAssertNil(PlateWebServer.parseByteRange("bytes=abc-def", fileSize: 1000)) // non-numeric
        XCTAssertNil(PlateWebServer.parseByteRange("bytes=500-100", fileSize: 1000)) // start>end
    }

    // MARK: - QuickTime GPS

    func testParseISO6709() {
        let coords = VideoMetadataReader.parseISO6709("+37.3318-122.0312+010.123/")
        XCTAssertEqual(coords?.lat ?? 0, 37.3318, accuracy: 0.0001)
        XCTAssertEqual(coords?.lon ?? 0, -122.0312, accuracy: 0.0001)
    }

    func testParseISO6709SouthWest() {
        let coords = VideoMetadataReader.parseISO6709("-33.8688+151.2093/")
        XCTAssertEqual(coords?.lat ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(coords?.lon ?? 0, 151.2093, accuracy: 0.0001)
    }

    func testParseISO6709RejectsGarbage() {
        XCTAssertNil(VideoMetadataReader.parseISO6709("not-a-coordinate"))
        XCTAssertNil(VideoMetadataReader.parseISO6709(""))
    }
}
