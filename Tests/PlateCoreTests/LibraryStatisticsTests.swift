import XCTest
@testable import PlateCore

final class LibraryStatisticsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: 0))!
    }

    private func asset(captured: Date? = nil,
                       camera: String? = nil,
                       lens: String? = nil,
                       focal: Double? = nil,
                       aperture: Double? = nil,
                       shutter: Double? = nil,
                       iso: Int? = nil,
                       lat: Double? = nil,
                       lon: Double? = nil,
                       raws: [String] = [],
                       favorite: Bool = false,
                       w: Int? = nil,
                       h: Int? = nil) -> Asset {
        Asset(primary: "p/\(UUID().uuidString).jpg",
              raws: raws,
              capturedAt: captured,
              pixelWidth: w,
              pixelHeight: h,
              isFavorite: favorite,
              cameraModel: camera,
              lensModel: lens,
              focalLength: focal,
              aperture: aperture,
              shutterSpeed: shutter,
              iso: iso,
              latitude: lat,
              longitude: lon)
    }

    /// Minimal asset with a controlled primary path + raws — for format tests.
    private func asset0(_ primary: String, raws: [String] = []) -> Asset {
        Asset(primary: primary, raws: raws)
    }

    func testTotalsAndFlags() {
        let assets = [
            asset(camera: "X2D 100C", raws: ["r.3fr"], favorite: true, w: 11656, h: 8742),
            asset(camera: "X2D 100C", favorite: false),
            asset(lat: 37.0, lon: -122.0),
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        XCTAssertEqual(s.totalPhotos, 3)
        XCTAssertEqual(s.favorites, 1)
        XCTAssertEqual(s.withRaw, 1)
        XCTAssertEqual(s.withGPS, 1)
        // Two assets carry camera metadata.
        XCTAssertEqual(s.withExif, 2)
        // ~101.9 MP for the one sized asset.
        XCTAssertEqual(s.totalMegapixels, 11656.0 * 8742.0 / 1_000_000.0, accuracy: 0.01)
    }

    func testCameraRankingDescending() {
        let assets = [
            asset(camera: "A"), asset(camera: "A"), asset(camera: "A"),
            asset(camera: "B"), asset(camera: "B"),
            asset(camera: "C"),
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        XCTAssertEqual(s.cameras.map(\.label), ["A", "B", "C"])
        XCTAssertEqual(s.cameras.map(\.count), [3, 2, 1])
    }

    func testFocalLengthSortedNumericallyNotLexically() {
        let assets = [
            asset(focal: 100), asset(focal: 24), asset(focal: 35), asset(focal: 35),
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        // Numeric order: 24, 35, 100 — not "100" < "24" < "35".
        XCTAssertEqual(s.focalLengths.map(\.label), ["24mm", "35mm", "100mm"])
        XCTAssertEqual(s.focalLengths.first(where: { $0.label == "35mm" })?.count, 2)
    }

    func testShutterFormattingAndOrder() {
        let assets = [
            asset(shutter: 1.0 / 250.0),
            asset(shutter: 2.0),
            asset(shutter: 1.0 / 8000.0),
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        // Fast → slow by actual duration.
        XCTAssertEqual(s.shutterSpeeds.map(\.label), ["1/8000", "1/250", "2s"])
    }

    func testApertureAndIsoFormatting() {
        XCTAssertEqual(LibraryStatistics.formatAperture(4.0), "f/4")
        XCTAssertEqual(LibraryStatistics.formatAperture(2.8), "f/2.8")
        let assets = [asset(iso: 100), asset(iso: 6400), asset(iso: 100)]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        XCTAssertEqual(s.isos.map(\.label), ["ISO 100", "ISO 6400"])
        XCTAssertEqual(s.isos.first?.count, 2)
    }

    func testTimeDistributions() {
        let assets = [
            asset(captured: date(2024, 1, 10, 9)),
            asset(captured: date(2024, 1, 20, 9)),
            asset(captured: date(2023, 6, 5, 14)),
            asset(captured: nil),   // undated — excluded from time buckets
        ]
        let s = LibraryStatistics.compute(from: assets, now: date(2025, 1, 1), calendar: cal)
        XCTAssertEqual(s.byYear.map(\.label), ["2023", "2024"])
        XCTAssertEqual(s.byYear.map(\.count), [1, 2])
        XCTAssertEqual(s.byMonth.count, 12)
        XCTAssertEqual(s.byMonth[0].count, 2)   // January
        XCTAssertEqual(s.byMonth[5].count, 1)   // June
        XCTAssertEqual(s.byHour.count, 24)
        XCTAssertEqual(s.byHour[9].count, 2)
        XCTAssertEqual(s.byHour[14].count, 1)
    }

    func testHeatmapBucketsByYearAndDay() {
        let assets = [
            asset(captured: date(2024, 3, 1)),
            asset(captured: date(2024, 3, 1)),
            asset(captured: date(2024, 3, 2)),
            asset(captured: date(2023, 12, 31)),
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        // Most-recent year first.
        XCTAssertEqual(s.heatmap.map(\.year), [2024, 2023])
        let y2024 = s.heatmap.first { $0.year == 2024 }!
        XCTAssertEqual(y2024.countsByDay["2024-03-01"], 2)
        XCTAssertEqual(y2024.countsByDay["2024-03-02"], 1)
        XCTAssertEqual(y2024.max, 2)
        XCTAssertEqual(y2024.total, 3)
    }

    func testOnThisDayMatchesMonthAndDayAcrossYears() {
        let target = asset(captured: date(2020, 5, 28))
        let alsoToday = asset(captured: date(2018, 5, 28))
        let notToday = asset(captured: date(2020, 5, 27))
        let s = LibraryStatistics.compute(from: [target, alsoToday, notToday],
                                          now: date(2025, 5, 28),
                                          calendar: cal)
        // Both May-28 assets, newest first.
        XCTAssertEqual(s.onThisDay, [target.id, alsoToday.id])
    }

    func testFormatLabelFoldsRawCompanions() {
        // Display master + RAW companion → folded "BASE + RAW".
        XCTAssertEqual(Asset(primary: "a/IMG.JPG", raws: ["a/IMG.NEF"]).formatLabel, "JPEG + RAW")
        XCTAssertEqual(Asset(primary: "a/IMG.heic", raws: ["a/IMG.3fr"]).formatLabel, "HEIF + RAW")
        XCTAssertEqual(Asset(primary: "a/IMG.TIF", raws: ["a/IMG.dng"]).formatLabel, "TIFF + RAW")
        // No companion → just the base type.
        XCTAssertEqual(Asset(primary: "a/IMG.jpeg").formatLabel, "JPEG")
        XCTAssertEqual(Asset(primary: "a/IMG.PNG").formatLabel, "PNG")
        // RAW primary (no display master) → "RAW", never "RAW + RAW".
        XCTAssertEqual(Asset(primary: "a/IMG.ARW").formatLabel, "RAW")
        XCTAssertEqual(Asset(primary: "a/IMG.cr3", raws: ["a/IMG.dng"]).formatLabel, "RAW")
    }

    func testFormatBreakdownFoldsAndRanks() {
        let assets = [
            asset0("x.JPG"), asset0("y.JPG"),
            asset0("z.JPG", raws: ["z.NEF"]),          // JPEG + RAW
            asset0("a.heic", raws: ["a.3fr"]),         // HEIF + RAW
            asset0("b.ARW"),                            // RAW
        ]
        let s = LibraryStatistics.compute(from: assets, calendar: cal)
        let dict = Dictionary(uniqueKeysWithValues: s.formats.map { ($0.label, $0.count) })
        XCTAssertEqual(dict["JPEG"], 2)
        XCTAssertEqual(dict["JPEG + RAW"], 1)
        XCTAssertEqual(dict["HEIF + RAW"], 1)
        XCTAssertEqual(dict["RAW"], 1)
        // Most common first.
        XCTAssertEqual(s.formats.first?.label, "JPEG")
        // Every asset is counted exactly once (folded, not double-counted).
        XCTAssertEqual(s.formats.reduce(0) { $0 + $1.count }, assets.count)
    }

    func testEmptyLibraryIsSafe() {
        let s = LibraryStatistics.compute(from: [], calendar: cal)
        XCTAssertEqual(s.totalPhotos, 0)
        XCTAssertTrue(s.cameras.isEmpty)
        XCTAssertTrue(s.heatmap.isEmpty)
        XCTAssertTrue(s.onThisDay.isEmpty)
        XCTAssertNil(s.earliestCapture)
        XCTAssertEqual(s.byMonth.count, 12)
    }
}
