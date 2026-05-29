import XCTest
@testable import PlateCore

/// Unit coverage for the pure, socket-free parts of the web server: HTTP request
/// parsing, response head serialization, and the constant-time token compare.
/// (Routing / file streaming are exercised end-to-end by `plate-cli serve`.)
final class WebServerTests: XCTestCase {

    /// Build a request head the way the server hands it to the parser: the bytes
    /// up to *but not including* the terminating blank line, CRLF-separated.
    private func head(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: - HTTPRequest.parse

    func testParsesMethodPathVersion() {
        let req = HTTPRequest.parse(head: head([
            "GET /thumb/abc HTTP/1.1",
            "Host: localhost",
        ]))
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/thumb/abc")
        XCTAssertEqual(req?.version, "HTTP/1.1")
        XCTAssertEqual(req?.target, "/thumb/abc")
    }

    func testParsesQueryItemsAndPercentEncoding() {
        let req = HTTPRequest.parse(head: head([
            "GET /api/assets?key=a%20b&x=1 HTTP/1.1",
        ]))
        XCTAssertEqual(req?.path, "/api/assets")
        XCTAssertEqual(req?.query["key"], "a b")   // %20 decoded
        XCTAssertEqual(req?.query["x"], "1")
    }

    func testHeaderNamesAreLowercasedAndTrimmed() {
        let req = HTTPRequest.parse(head: head([
            "GET / HTTP/1.1",
            "Content-Type:   application/json  ",
            "AUTHORIZATION: Basic Zm9v",
        ]))
        XCTAssertEqual(req?.headers["content-type"], "application/json")
        XCTAssertEqual(req?.headers["authorization"], "Basic Zm9v")
    }

    func testKeepAliveSemantics() {
        // HTTP/1.1 defaults to keep-alive.
        XCTAssertEqual(HTTPRequest.parse(head: head(["GET / HTTP/1.1"]))?.wantsKeepAlive, true)
        // …unless the client says close.
        XCTAssertEqual(HTTPRequest.parse(head: head([
            "GET / HTTP/1.1", "Connection: close",
        ]))?.wantsKeepAlive, false)
        // HTTP/1.0 defaults to close.
        XCTAssertEqual(HTTPRequest.parse(head: head(["GET / HTTP/1.0"]))?.wantsKeepAlive, false)
        // …unless it explicitly asks to keep alive.
        XCTAssertEqual(HTTPRequest.parse(head: head([
            "GET / HTTP/1.0", "Connection: keep-alive",
        ]))?.wantsKeepAlive, true)
    }

    func testParsesHeadMethod() {
        XCTAssertEqual(HTTPRequest.parse(head: head(["HEAD /preview/x HTTP/1.1"]))?.method, "HEAD")
    }

    func testRejectsMalformedRequestLine() {
        XCTAssertNil(HTTPRequest.parse(head: head(["GET /only-two-tokens"])))
        XCTAssertNil(HTTPRequest.parse(head: Data()))
    }

    func testToleratesBareLF() {
        // A client (or test) using bare LF instead of CRLF still parses.
        let req = HTTPRequest.parse(head: Data("GET /x HTTP/1.1\nHost: a".utf8))
        XCTAssertEqual(req?.path, "/x")
        XCTAssertEqual(req?.headers["host"], "a")
    }

    // MARK: - HTTPResponse.serializedHead

    func testSerializedHeadInjectsLengthAndConnection() {
        let head = HTTPResponse.json(Data("{}".utf8)).serializedHead(keepAlive: true)
        let text = String(data: head, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))      // "{}" is 2 bytes
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))                  // blank-line terminator
    }

    func testSerializedHeadCloseAndDefaultReasons() {
        let head = HTTPResponse.text("Nope", status: 404).serializedHead(keepAlive: false)
        let text = String(data: head, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
    }

    // MARK: - constant-time compare

    func testConstantTimeEqual() {
        XCTAssertTrue(PlateWebServer.constantTimeEqual("s3cret", "s3cret"))
        XCTAssertFalse(PlateWebServer.constantTimeEqual("s3cret", "s3creT"))
        XCTAssertFalse(PlateWebServer.constantTimeEqual("s3cret", "s3cret-longer"))
        XCTAssertFalse(PlateWebServer.constantTimeEqual("", "x"))
        XCTAssertTrue(PlateWebServer.constantTimeEqual("", ""))
    }

    func testGeneratedTokenIsHexAndUnique() {
        let a = PlateWebServer.generateToken()
        let b = PlateWebServer.generateToken()
        XCTAssertEqual(a.count, 32)                                  // 16 bytes → 32 hex chars
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }
}
