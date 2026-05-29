import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import PlateCore

final class ExifReaderTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExifTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Write a small JPEG carrying a full EXIF/TIFF/GPS block, then read it back
    /// through ExifReader to confirm every field is parsed end-to-end.
    func testReadsFullExifBlock() throws {
        let url = tempRoot.appendingPathComponent("shot.jpg")
        try writeJPEG(at: url, properties: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Hasselblad",
                kCGImagePropertyTIFFModel: "X2D 100C",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:07:15 18:30:00",
                kCGImagePropertyExifLensModel: "XCD 4/45P",
                kCGImagePropertyExifFocalLength: 45.0,
                kCGImagePropertyExifFNumber: 4.0,
                kCGImagePropertyExifExposureTime: 1.0 / 250.0,
                kCGImagePropertyExifISOSpeedRatings: [400],
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ])

        let meta = ExifReader.readMetadata(for: url)
        XCTAssertEqual(meta.cameraMake, "Hasselblad")
        XCTAssertEqual(meta.cameraModel, "X2D 100C")
        XCTAssertEqual(meta.lensModel, "XCD 4/45P")
        XCTAssertEqual(meta.focalLength ?? 0, 45.0, accuracy: 0.01)
        XCTAssertEqual(meta.aperture ?? 0, 4.0, accuracy: 0.01)
        XCTAssertEqual(meta.shutterSpeed ?? 0, 1.0 / 250.0, accuracy: 0.0001)
        XCTAssertEqual(meta.iso, 400)
        XCTAssertEqual(meta.latitude ?? 0, 37.7749, accuracy: 0.0001)
        // West longitude must come back negative.
        XCTAssertEqual(meta.longitude ?? 0, -122.4194, accuracy: 0.0001)
        XCTAssertNotNil(meta.capturedAt)
        XCTAssertNotNil(meta.pixelWidth)
    }

    /// A file with no EXIF still yields dimensions + an mtime-based capture date,
    /// and leaves all shooting fields nil (the "screenshot / scan" case).
    func testNoExifLeavesShootingFieldsNil() throws {
        let url = tempRoot.appendingPathComponent("plain.jpg")
        try writeJPEG(at: url, properties: [:])

        let meta = ExifReader.readMetadata(for: url)
        XCTAssertNil(meta.cameraMake)
        XCTAssertNil(meta.lensModel)
        XCTAssertNil(meta.aperture)
        XCTAssertNil(meta.iso)
        XCTAssertNil(meta.latitude)
        XCTAssertNotNil(meta.capturedAt)   // falls back to file mtime
        XCTAssertNotNil(meta.pixelWidth)
    }

    // MARK: - Helpers

    private func writeJPEG(at url: URL, properties: [CFString: Any]) throws {
        let w = 64, h = 48
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "test", code: 1)
        }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = ctx.makeImage() else { throw NSError(domain: "test", code: 2) }

        let type = UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw NSError(domain: "test", code: 3)
        }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 0.8
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 4) }
    }
}
