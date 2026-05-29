import Foundation

/// Minimal HTTP/1.1 request — only what a read-only photo server needs.
///
/// We parse the request *head* (request line + header block). The server only
/// answers GET / HEAD, neither of which carries a body, so there's nothing to
/// consume after the terminating blank line. Kept deliberately small and pure
/// so it can be unit-tested without a socket.
struct HTTPRequest: Equatable {
    /// Raw method token, upper-cased ("GET", "HEAD", "POST", …).
    let method: String
    /// The original request target, e.g. "/thumb/abc?key=xyz".
    let target: String
    /// Percent-decoded path component, e.g. "/thumb/abc".
    let path: String
    /// Decoded query items. `?key=` is the only one we read; last value wins.
    let query: [String: String]
    /// "HTTP/1.1" / "HTTP/1.0".
    let version: String
    /// Header names lower-cased (HTTP header names are case-insensitive).
    let headers: [String: String]

    /// HTTP/1.1 keeps the connection alive unless the client says `close`;
    /// HTTP/1.0 is the opposite (close unless it asks to keep-alive).
    var wantsKeepAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" { return connection == "keep-alive" }
        return connection != "close"
    }

    /// Parse the head bytes (everything up to, but excluding, the CRLFCRLF that
    /// terminates the header block). Returns nil only for a malformed request
    /// line — the caller answers 400 in that case.
    static func parse(head: Data) -> HTTPRequest? {
        // Headers are ASCII/Latin-1 by spec; fall back to Latin-1 so a stray
        // high byte can't make the whole parse fail.
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return nil }

        // Normalise CRLF → LF so a bare-LF client (curl piping, tests) still parses.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }

        // "METHOD SP target SP version" — exactly three space-separated tokens.
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let method = parts[0].uppercased()
        let target = String(parts[1])
        let version = String(parts[2])

        // Split target into path + raw query.
        let rawPath: String
        let queryString: String
        if let q = target.firstIndex(of: "?") {
            rawPath = String(target[..<q])
            queryString = String(target[target.index(after: q)...])
        } else {
            rawPath = target
            queryString = ""
        }
        let path = rawPath.removingPercentEncoding ?? rawPath

        var query: [String: String] = [:]
        if !queryString.isEmpty {
            for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                // Leave `+` literal — generic query strings (not form bodies) don't
                // treat it as space, and our tokens are hex anyway.
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                if !key.isEmpty { query[key] = value }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }

        return HTTPRequest(method: method, target: target, path: path,
                           query: query, version: version, headers: headers)
    }
}

/// A response with an inline body. Small generated payloads (HTML, JSON, JPEG
/// previews, error text) flow through here. Large originals are streamed by the
/// server straight off disk and only borrow `serializedHead(keepAlive:)`.
struct HTTPResponse {
    var status: Int
    var reason: String
    /// Ordered so callers control header order; names are sent verbatim.
    var headers: [(String, String)]
    var body: Data?

    init(status: Int, reason: String? = nil,
         headers: [(String, String)] = [], body: Data? = nil) {
        self.status = status
        self.reason = reason ?? HTTPResponse.defaultReason(for: status)
        self.headers = headers
        self.body = body
    }

    /// Status line + headers + blank line, ready to write. `Content-Length`
    /// (from the body unless a caller supplied its own, e.g. streamed files),
    /// `Connection`, and a couple of fixed hardening headers are injected here
    /// so every route stays consistent.
    func serializedHead(keepAlive: Bool) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        var sawContentLength = false
        for (name, value) in headers {
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                sawContentLength = true
            }
            lines.append("\(name): \(value)")
        }
        if !sawContentLength {
            lines.append("Content-Length: \(body?.count ?? 0)")
        }
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        lines.append("Server: Plate")
        // Browsers shouldn't second-guess our declared content types.
        lines.append("X-Content-Type-Options: nosniff")
        lines.append("")   // ── blank line ──
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: - Convenience builders

    static func html(_ markup: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [("Content-Type", "text/html; charset=utf-8")],
                     body: Data(markup.utf8))
    }

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [("Content-Type", "application/json; charset=utf-8")],
                     body: data)
    }

    static func text(_ message: String, status: Int,
                     extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [("Content-Type", "text/plain; charset=utf-8")] + extraHeaders,
                     body: Data((message + "\n").utf8))
    }

    static let noContent = HTTPResponse(status: 204)

    static func defaultReason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}
