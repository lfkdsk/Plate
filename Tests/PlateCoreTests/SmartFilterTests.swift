import XCTest
@testable import PlateCore

final class SmartFilterTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: - Compiler (pure)

    func testEmptyFilterCompilesToNothing() {
        let c = SmartFilter().compile(calendar: cal)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.whereSQL, "")
        XCTAssertTrue(c.bindings.isEmpty)
    }

    func testNumberRulesMapToBoundComparisons() {
        let c = SmartFilter(rules: [.iso(.atLeast(400))]).compile(calendar: cal)
        XCTAssertEqual(c.whereSQL, "((iso >= ?))")
        XCTAssertEqual(c.bindings, [.double(400)])

        let between = SmartFilter(rules: [.aperture(.between(2.8, 1.4))]).compile(calendar: cal)
        // Operands normalised low→high.
        XCTAssertEqual(between.whereSQL, "((aperture BETWEEN ? AND ?))")
        XCTAssertEqual(between.bindings, [.double(1.4), .double(2.8)])
    }

    func testTextRulesEscapeAndBind() {
        let isC = SmartFilter(rules: [.camera(.is("X2D 100C"))]).compile(calendar: cal)
        XCTAssertEqual(isC.whereSQL, "((camera_model = ? COLLATE NOCASE))")
        XCTAssertEqual(isC.bindings, [.text("X2D 100C")])

        let notC = SmartFilter(rules: [.camera(.isNot("Canon"))]).compile(calendar: cal)
        // Unknown-camera rows are "not Canon" → included via IS NULL.
        XCTAssertEqual(notC.whereSQL, "((camera_model IS NULL OR camera_model <> ? COLLATE NOCASE))")

        let contains = SmartFilter(rules: [.lens(.contains("50%_mm"))]).compile(calendar: cal)
        XCTAssertTrue(contains.whereSQL.contains("LIKE ? ESCAPE '\\' COLLATE NOCASE"))
        // % and _ in the needle are escaped so they're literal.
        XCTAssertEqual(contains.bindings, [.text("%50\\%\\_mm%")])
    }

    func testFlagRulesAreLiteralNoBindings() {
        XCTAssertEqual(SmartFilter(rules: [.isFavorite(true)]).compile(calendar: cal).whereSQL,
                       "((is_favorite = 1))")
        XCTAssertEqual(SmartFilter(rules: [.hasRaw(true)]).compile(calendar: cal).whereSQL,
                       "((raws_json IS NOT NULL AND raws_json <> '[]'))")
        XCTAssertEqual(SmartFilter(rules: [.hasGPS(false)]).compile(calendar: cal).whereSQL,
                       "((latitude IS NULL OR longitude IS NULL))")
        XCTAssertTrue(SmartFilter(rules: [.hasRaw(true)]).compile(calendar: cal).bindings.isEmpty)
    }

    func testYearExpandsToHalfOpenRange() {
        let c = SmartFilter(rules: [.captured(.year(2024))]).compile(calendar: cal)
        XCTAssertEqual(c.whereSQL, "((captured_at >= ? AND captured_at < ?))")
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        XCTAssertEqual(c.bindings, [.double(start.timeIntervalSince1970),
                                    .double(end.timeIntervalSince1970)])
    }

    func testAllVsAnyJoiner() {
        let rules: [SmartFilter.Rule] = [.isFavorite(true), .hasRaw(true)]
        let all = SmartFilter(match: .all, rules: rules).compile(calendar: cal)
        XCTAssertEqual(all.whereSQL, "((is_favorite = 1) AND (raws_json IS NOT NULL AND raws_json <> '[]'))")
        let any = SmartFilter(match: .any, rules: rules).compile(calendar: cal)
        XCTAssertEqual(any.whereSQL, "((is_favorite = 1) OR (raws_json IS NOT NULL AND raws_json <> '[]'))")
    }

    func testBindingsConcatenateInRuleOrder() {
        let c = SmartFilter(rules: [
            .camera(.is("X2D 100C")),
            .iso(.atMost(800)),
            .lens(.contains("XCD")),
        ]).compile(calendar: cal)
        XCTAssertEqual(c.bindings, [.text("X2D 100C"), .double(800), .text("%XCD%")])
    }

    // MARK: - Integration (against SQLite)

    func testFilterExecutesAgainstStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartFilter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lib = try PlateLibrary.create(at: root.appendingPathComponent("F.plate"))

        // PlateLibrary's store is private and importPairs needs real image files,
        // so seed rows by opening a second AssetStore on the same db file, then
        // reopen the library to read them back through the public filter API.
        let direct = try AssetStore(url: lib.databaseURL)
        let hassel = Asset(primary: "a/1.JPG", raws: ["a/1.3FR"], capturedAt: date(2024, 6, 1),
                           isFavorite: true, cameraModel: "X2D 100C", lensModel: "XCD 4/45P",
                           focalLength: 45, aperture: 4, iso: 100, latitude: 37, longitude: -122)
        let sony = Asset(primary: "a/2.JPG", capturedAt: date(2023, 3, 1),
                         cameraModel: "ILCE-7M4", lensModel: "FE 35mm F1.4 GM",
                         focalLength: 35, aperture: 1.4, iso: 3200)
        let phone = Asset(primary: "a/3.HEIC", capturedAt: date(2024, 8, 1),
                          cameraModel: "iPhone 15 Pro", iso: 400)
        try direct.insert(hassel)
        try direct.insert(sony)
        try direct.insert(phone)

        // Reopen the library so it sees the freshly-inserted rows.
        let reopened = try PlateLibrary.open(at: lib.url)

        // Single rule: favorites only.
        XCTAssertEqual(reopened.assets(matching: SmartFilter(rules: [.isFavorite(true)])).map(\.primary),
                       ["a/1.JPG"])

        // Numeric: ISO >= 400 → phone + sony (NULL-iso excluded; none here).
        let highISO = reopened.assets(matching: SmartFilter(rules: [.iso(.atLeast(400))]))
        XCTAssertEqual(Set(highISO.map(\.primary)), ["a/2.JPG", "a/3.HEIC"])

        // Has RAW.
        XCTAssertEqual(reopened.assets(matching: SmartFilter(rules: [.hasRaw(true)])).map(\.primary),
                       ["a/1.JPG"])

        // Geotagged.
        XCTAssertEqual(reopened.assets(matching: SmartFilter(rules: [.hasGPS(true)])).map(\.primary),
                       ["a/1.JPG"])

        // Year 2024 → hassel + phone, newest first (Aug before Jun).
        XCTAssertEqual(reopened.assets(matching: SmartFilter(rules: [.captured(.year(2024))])).map(\.primary),
                       ["a/3.HEIC", "a/1.JPG"])

        // match=.all: camera contains "ILCE" AND aperture <= 2 → sony only.
        let combo = SmartFilter(match: .all, rules: [.camera(.contains("ILCE")), .aperture(.atMost(2))])
        XCTAssertEqual(reopened.assets(matching: combo).map(\.primary), ["a/2.JPG"])

        // match=.any: favorite OR iso >= 3000 → hassel + sony.
        let anyF = SmartFilter(match: .any, rules: [.isFavorite(true), .iso(.atLeast(3000))])
        XCTAssertEqual(Set(reopened.assets(matching: anyF).map(\.primary)), ["a/1.JPG", "a/2.JPG"])

        // Empty filter → everything (3).
        XCTAssertEqual(reopened.assets(matching: SmartFilter()).count, 3)

        // Distinct helpers.
        XCTAssertEqual(reopened.distinctCameras, ["ILCE-7M4", "iPhone 15 Pro", "X2D 100C"])
        XCTAssertEqual(reopened.distinctCaptureYears, [2024, 2023])
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
}
