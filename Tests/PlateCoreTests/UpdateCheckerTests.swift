import XCTest
@testable import PlateCore

final class UpdateCheckerTests: XCTestCase {

    typealias Version = UpdateChecker.SemanticVersion

    // MARK: - Version parsing

    func testParsesVariousTagFormats() {
        XCTAssertEqual(Version("1.2.3"), Version(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(Version("v1.2.3"), Version(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(Version("V2.0.0"), Version(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(Version("  0.1.0 "), Version(major: 0, minor: 1, patch: 0))
        // Missing components default to 0.
        XCTAssertEqual(Version("1"), Version(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(Version("1.5"), Version(major: 1, minor: 5, patch: 0))
        // Pre-release / build metadata is dropped.
        XCTAssertEqual(Version("1.2.0-beta.1"), Version(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(Version("v3.4.5+build.99"), Version(major: 3, minor: 4, patch: 5))
    }

    func testRejectsNonNumericTags() {
        XCTAssertNil(Version("latest"))
        XCTAssertNil(Version("vNext"))
        XCTAssertNil(Version(""))
    }

    func testVersionOrdering() {
        XCTAssertTrue(Version("0.9.0")! < Version("0.10.0")!)   // numeric, not lexical
        XCTAssertTrue(Version("1.0.0")! < Version("1.0.1")!)
        XCTAssertTrue(Version("1.2.0")! < Version("2.0.0")!)
        XCTAssertEqual(Version("1.0")!, Version("1.0.0")!)
        XCTAssertFalse(Version("2.0.0")! < Version("1.9.9")!)
    }

    // MARK: - Payload parsing

    private func payload(tag: String, url: String = "https://github.com/lfkdsk/HSMA/releases/tag/x",
                         body: String = "notes") -> Data {
        """
        { "tag_name": "\(tag)", "html_url": "\(url)", "body": "\(body)" }
        """.data(using: .utf8)!
    }

    func testParseLatestReleaseHappyPath() throws {
        let r = try UpdateChecker.parseLatestRelease(payload(tag: "v0.2.0", body: "Shiny"))
        XCTAssertEqual(r.version, Version(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(r.tagName, "v0.2.0")
        XCTAssertEqual(r.htmlURL.absoluteString, "https://github.com/lfkdsk/HSMA/releases/tag/x")
        XCTAssertEqual(r.notes, "Shiny")
    }

    func testParseLatestReleaseRejectsBadPayloads() {
        XCTAssertThrowsError(try UpdateChecker.parseLatestRelease(Data("not json".utf8)))
        XCTAssertThrowsError(try UpdateChecker.parseLatestRelease(Data("{}".utf8)))         // no tag
        XCTAssertThrowsError(try UpdateChecker.parseLatestRelease(payload(tag: "nightly"))) // unparseable
    }

    // MARK: - Upgrade decision

    func testUpgradeOnlyWhenStrictlyNewer() throws {
        let r = try UpdateChecker.parseLatestRelease(payload(tag: "v1.0.0"))
        XCTAssertNotNil(UpdateChecker.upgrade(from: Version("0.9.0")!, to: r))   // newer → offer
        XCTAssertNil(UpdateChecker.upgrade(from: Version("1.0.0")!, to: r))      // same → no
        XCTAssertNil(UpdateChecker.upgrade(from: Version("1.1.0")!, to: r))      // older remote → no
    }

    // MARK: - End-to-end with injected fetcher (no network)

    func testCheckReturnsReleaseWhenNewer() {
        let exp = expectation(description: "check")
        let fetch: (URL, @escaping (Result<Data, Error>) -> Void) -> Void = { _, done in
            done(.success(self.payload(tag: "v0.5.0")))
        }
        UpdateChecker.check(owner: "lfkdsk", repo: "HSMA", currentVersion: "0.1.0", fetch: fetch) { result in
            if case .success(let release) = result {
                XCTAssertEqual(release?.tagName, "v0.5.0")
            } else {
                XCTFail("expected success with a release")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testCheckReturnsNilWhenUpToDate() {
        let exp = expectation(description: "check")
        let fetch: (URL, @escaping (Result<Data, Error>) -> Void) -> Void = { _, done in
            done(.success(self.payload(tag: "v0.1.0")))
        }
        UpdateChecker.check(owner: "lfkdsk", repo: "HSMA", currentVersion: "0.1.0", fetch: fetch) { result in
            if case .success(let release) = result {
                XCTAssertNil(release)
            } else {
                XCTFail("expected success(nil)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testCheckPropagatesNetworkFailure() {
        let exp = expectation(description: "check")
        struct Boom: Error {}
        let fetch: (URL, @escaping (Result<Data, Error>) -> Void) -> Void = { _, done in
            done(.failure(Boom()))
        }
        UpdateChecker.check(owner: "lfkdsk", repo: "HSMA", currentVersion: "0.1.0", fetch: fetch) { result in
            if case .failure = result { /* expected */ } else { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testLatestReleaseURLShape() {
        XCTAssertEqual(UpdateChecker.latestReleaseURL(owner: "lfkdsk", repo: "HSMA").absoluteString,
                       "https://api.github.com/repos/lfkdsk/HSMA/releases/latest")
    }
}
