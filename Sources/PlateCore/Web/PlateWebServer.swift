import Foundation
import Network
import Security

/// A tiny, dependency-free HTTP server that exposes a `PlateLibrary` as a
/// read-only web gallery. Built on `Network.framework` (`NWListener`) so it
/// links nothing beyond the system — same spirit as the rest of PlateCore,
/// which only borrows `sqlite3` and ImageIO.
///
/// It speaks just enough HTTP/1.1 for a browser: GET/HEAD, keep-alive, and
/// chunk-streamed file bodies so a 100 MB RAW download never lands in memory.
/// Designed to sit behind a Cloudflare Tunnel — it binds **loopback only** by
/// default, so the only way in from outside is whatever you point at
/// `127.0.0.1:<port>`. Auth is a single shared token (see `Configuration`).
///
/// Routes:
///   GET /                  → the embedded gallery page (WebFrontend)
///   GET /api/assets        → JSON: { library, count, assets:[…] }
///   GET /thumb/<id>        → import-time 512px JPEG thumbnail (video: poster)
///   GET /preview/<id>      → ~2048px JPEG rendition (generated + cached;
///                            video falls back to the poster thumbnail)
///   GET /original/<id>     → the original file (stills: attachment download;
///                            video: inline, Range-served for <video> playback)
///   GET /motion/<id>       → a Live Photo's motion .mov, inline (Range-served)
///
/// Everything is read-only: there is no route that mutates the library.
public final class PlateWebServer {

    public struct Configuration {
        /// TCP port to listen on.
        public var port: UInt16
        /// Shared secret. Empty/nil ⇒ no authentication (LAN-only convenience).
        /// When set, every request must present it via HTTP Basic auth
        /// (password field; username ignored) or `?key=<token>`.
        public var token: String?
        /// false (default) ⇒ bind 127.0.0.1 only — the safe pairing with a
        /// tunnel. true ⇒ bind all interfaces so other devices on the LAN can
        /// reach it directly.
        public var bindAllInterfaces: Bool

        public init(port: UInt16 = 8080, token: String? = nil, bindAllInterfaces: Bool = false) {
            self.port = port
            self.token = token
            self.bindAllInterfaces = bindAllInterfaces
        }
    }

    public enum ServerError: Error, CustomStringConvertible {
        case invalidPort(UInt16)
        case portInUse(UInt16)
        case startupFailed(String)

        public var description: String {
            switch self {
            case .invalidPort(let p):  return "Invalid port: \(p)"
            case .portInUse(let p):    return "Port \(p) is already in use"
            case .startupFailed(let m): return "Web server failed to start: \(m)"
            }
        }
    }

    private let library: PlateLibrary
    private let config: Configuration
    /// Concurrent so connections are handled in parallel; shared state below is
    /// individually guarded.
    private let queue = DispatchQueue(label: "com.lfkdsk.Plate.WebServer", attributes: .concurrent)
    private var listener: NWListener?

    private let indexLock = NSLock()
    /// id(lowercased) → Asset, built lazily so `/thumb` and `/original` resolve
    /// without an O(n) scan per request. Rebuilt by `/api/assets` and cleared by
    /// `reload()` after the app imports.
    private var assetIndex: [String: Asset]?

    private let stateLock = NSLock()
    private var _isRunning = false

    public init(library: PlateLibrary, configuration: Configuration) {
        self.library = library
        self.config = configuration
    }

    // MARK: - Public surface

    public var port: UInt16 { config.port }
    public var requiresAuth: Bool { !(config.token ?? "").isEmpty }
    /// The configured shared secret, if any. Exposed so a UI can display it; it
    /// is the user's own secret (and already embedded in `localURLWithToken`).
    public var token: String? { config.token }
    public var bindsAllInterfaces: Bool { config.bindAllInterfaces }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    /// Loopback URL for local use / display.
    public var localURL: String { "http://127.0.0.1:\(config.port)/" }

    /// Loopback URL with the token pre-attached — handy for "Open in Browser"
    /// so the local machine skips the auth prompt. Don't share this one; it
    /// embeds the secret.
    public var localURLWithToken: String {
        guard let token = config.token, !token.isEmpty else { return localURL }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return "http://127.0.0.1:\(config.port)/?key=\(encoded)"
    }

    /// Generate a 128-bit URL-safe hex token. Used by callers that didn't supply
    /// their own secret (secure-by-default).
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Cryptographic RNG should never fail on macOS; fall back to a UUID so
        // we still return *something* unguessable rather than crashing.
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Drop the cached asset index so the next request re-reads the library.
    /// The app calls this after an import so newly added photos show up.
    public func reload() {
        indexLock.lock(); assetIndex = nil; indexLock.unlock()
    }

    // MARK: - Lifecycle

    /// Start listening. Blocks until the listener reaches `.ready` (success) or
    /// fails (e.g. the port is taken), so callers get a synchronous throw on the
    /// common "address in use" case rather than a silent no-op.
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: config.port) else {
            throw ServerError.invalidPort(config.port)
        }

        let params = NWParameters.tcp
        // Avoid lingering TIME_WAIT blocking a quick restart on the same port.
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if config.bindAllInterfaces {
                // All interfaces — the port goes to the initializer.
                listener = try NWListener(using: params, on: nwPort)
            } else {
                // Loopback only: the only thing that can then reach us is
                // something explicitly forwarding to 127.0.0.1 — i.e. a
                // Cloudflare Tunnel — never a stranger on the same Wi-Fi. Pin the
                // local endpoint to 127.0.0.1 and let the listener take its port
                // from there. Passing `on:` *and* a requiredLocalEndpoint with a
                // port conflicts (EINVAL), so it's one or the other.
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                listener = try NWListener(using: params)
            }
        } catch {
            throw ServerError.startupFailed("\(error)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setRunning(true)
                semaphore.signal()
            case .failed(let error), .waiting(let error):
                // `.waiting` is how NWListener reports e.g. EADDRINUSE: it parks
                // and retries. We treat that as a hard startup failure instead
                // of hanging.
                startError = error
                semaphore.signal()
            case .cancelled:
                self?.setRunning(false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw ServerError.startupFailed("timed out waiting for the listener to come up")
        }
        if let error = startError {
            listener.cancel()
            self.listener = nil
            throw Self.map(error, port: config.port)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        setRunning(false)
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); _isRunning = value; stateLock.unlock()
    }

    private static func map(_ error: Error, port: UInt16) -> ServerError {
        if case let NWError.posix(code) = error, code == .EADDRINUSE {
            return .portInUse(port)
        }
        return .startupFailed("\(error)")
    }

    // MARK: - Connection handling

    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeadBytes = 64 * 1024
    private static let streamChunk = 256 * 1024

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    /// Accumulate bytes until we have a full request head (CRLFCRLF), then route
    /// it. Since GET/HEAD carry no body, the head *is* the whole request.
    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }

            var buffer = buffer
            if let chunk = chunk, !chunk.isEmpty { buffer.append(chunk) }

            if let range = buffer.range(of: PlateWebServer.headTerminator) {
                let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                guard let request = HTTPRequest.parse(head: headData) else {
                    self.respond(.text("Bad Request", status: 400),
                                 to: nil, on: connection, keepAlive: false)
                    return
                }
                self.route(request, on: connection)
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }
            if buffer.count > PlateWebServer.maxHeadBytes {
                self.respond(.text("Request header too large", status: 431),
                             to: nil, on: connection, keepAlive: false)
                return
            }
            self.receiveHead(on: connection, buffer: buffer)
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        let keepAlive = request.wantsKeepAlive

        guard request.method == "GET" || request.method == "HEAD" else {
            respond(.text("Method Not Allowed", status: 405,
                          extraHeaders: [("Allow", "GET, HEAD")]),
                    to: request, on: connection, keepAlive: keepAlive)
            return
        }

        guard authorized(request) else {
            // 401 + WWW-Authenticate makes the browser pop its native login
            // sheet; the user types the token as the password.
            respond(HTTPResponse(
                        status: 401,
                        headers: [("WWW-Authenticate", "Basic realm=\"Plate\", charset=\"UTF-8\""),
                                  ("Content-Type", "text/plain; charset=utf-8")],
                        body: Data("Authentication required.\n".utf8)),
                    to: request, on: connection, keepAlive: keepAlive)
            return
        }

        switch request.path {
        case "/", "/index.html":
            respond(.html(WebFrontend.html(libraryName: libraryName)),
                    to: request, on: connection, keepAlive: keepAlive)
        case "/api/assets":
            respond(assetsJSONResponse(), to: request, on: connection, keepAlive: keepAlive)
        case "/favicon.ico":
            respond(.noContent, to: request, on: connection, keepAlive: keepAlive)
        default:
            if let id = id(in: request.path, after: "/thumb/") {
                serveThumbnail(id: id, request: request, on: connection, keepAlive: keepAlive)
            } else if let id = id(in: request.path, after: "/preview/") {
                servePreview(id: id, request: request, on: connection, keepAlive: keepAlive)
            } else if let id = id(in: request.path, after: "/original/") {
                serveOriginal(id: id, request: request, on: connection, keepAlive: keepAlive)
            } else if let id = id(in: request.path, after: "/motion/") {
                serveMotion(id: id, request: request, on: connection, keepAlive: keepAlive)
            } else if let rest = id(in: request.path, after: "/raw/") {
                serveCompanion(rest, kind: .raw, request: request, on: connection, keepAlive: keepAlive)
            } else if let rest = id(in: request.path, after: "/sidecar/") {
                serveCompanion(rest, kind: .sidecar, request: request, on: connection, keepAlive: keepAlive)
            } else {
                respond(.text("Not Found", status: 404),
                        to: request, on: connection, keepAlive: keepAlive)
            }
        }
    }

    private func id(in path: String, after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }

    private var libraryName: String {
        library.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Auth

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let token = config.token, !token.isEmpty else { return true }

        if let key = request.query["key"], Self.constantTimeEqual(key, token) {
            return true
        }
        if let auth = request.headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "basic",
               let decoded = Data(base64Encoded: String(parts[1])),
               let credentials = String(data: decoded, encoding: .utf8) {
                // credentials are "username:password"; the token is the password,
                // the username is ignored.
                let password: String
                if let colon = credentials.firstIndex(of: ":") {
                    password = String(credentials[credentials.index(after: colon)...])
                } else {
                    password = credentials
                }
                if Self.constantTimeEqual(password, token) { return true }
            }
        }
        return false
    }

    /// Length-independent byte comparison — avoids leaking the token length or a
    /// prefix match through response timing.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        let n = max(x.count, y.count)
        var i = 0
        while i < n {
            let xb = i < x.count ? x[i] : 0
            let yb = i < y.count ? y[i] : 0
            diff |= (xb ^ yb)
            i += 1
        }
        return diff == 0
    }

    // MARK: - /api/assets

    private struct AssetsEnvelope: Encodable {
        let library: String
        let count: Int
        let assets: [AssetDTO]
    }

    /// What the gallery page needs per photo. Pixel dims feed the justified
    /// layout; EXIF feeds the lightbox info panel. Shutter/aperture/focal stay
    /// raw numbers — the frontend formats them ("1/250s", "f/4", "45mm").
    private struct AssetDTO: Encodable {
        let id: String
        let w: Int
        let h: Int
        let captured: Double?     // epoch seconds, or null
        let favorite: Bool
        let format: String
        let camera: String?
        let lens: String?
        let focal: Double?
        let aperture: Double?
        let shutter: Double?
        let iso: Int?
        let gps: Bool
        let filename: String
        let ext: String
        /// Media kind: "image" / "video" / "livePhoto". The frontend uses it to
        /// pick a tile badge and a lightbox renderer (`<img>` vs `<video>`).
        let kind: String
        /// Video duration in seconds (null for stills / Live Photos).
        let duration: Double?
        /// Lower-cased extensions of the RAW companions (e.g. ["3fr"]) and
        /// XMP/AAE sidecars — the frontend turns these into download buttons
        /// addressed by index (`/raw/<id>/<i>`, `/sidecar/<id>/<i>`).
        let raws: [String]
        let sidecars: [String]

        init(_ asset: Asset) {
            id = asset.id.uuidString.lowercased()
            w = asset.pixelWidth ?? 0
            h = asset.pixelHeight ?? 0
            captured = asset.capturedAt?.timeIntervalSince1970
            favorite = asset.isFavorite
            format = asset.formatLabel
            camera = asset.cameraName
            lens = asset.lensModel
            focal = asset.focalLength
            aperture = asset.aperture
            shutter = asset.shutterSpeed
            iso = asset.iso
            gps = (asset.latitude != nil && asset.longitude != nil)
            filename = (asset.primary as NSString).lastPathComponent
            ext = (asset.primary as NSString).pathExtension.lowercased()
            kind = asset.mediaType.rawValue
            duration = asset.duration
            raws = asset.raws.map { ($0 as NSString).pathExtension.lowercased() }
            sidecars = asset.sidecars.map { ($0 as NSString).pathExtension.lowercased() }
        }
    }

    private func assetsJSONResponse() -> HTTPResponse {
        let assets = library.assets
        // Refresh the lookup index so subsequent /thumb /preview /original
        // requests (which the page is about to fire) resolve against exactly the
        // set the page was given.
        let fresh = Dictionary(assets.map { ($0.id.uuidString.lowercased(), $0) },
                               uniquingKeysWith: { first, _ in first })
        indexLock.lock(); assetIndex = fresh; indexLock.unlock()

        let envelope = AssetsEnvelope(library: libraryName,
                                      count: assets.count,
                                      assets: assets.map(AssetDTO.init))
        guard let data = try? JSONEncoder().encode(envelope) else {
            return .text("Encoding error", status: 500)
        }
        return .json(data)
    }

    private func asset(for id: String) -> Asset? {
        let key = id.lowercased()
        indexLock.lock(); defer { indexLock.unlock() }
        if assetIndex == nil {
            assetIndex = Dictionary(library.assets.map { ($0.id.uuidString.lowercased(), $0) },
                                    uniquingKeysWith: { first, _ in first })
        }
        return assetIndex?[key]
    }

    // MARK: - Image routes

    private func serveThumbnail(id: String, request: HTTPRequest,
                                on connection: NWConnection, keepAlive: Bool) {
        guard let asset = asset(for: id) else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        // Prefer the thumbnail generated at import time.
        if let thumb = asset.thumbnail {
            let url = library.absoluteURL(forRelative: thumb)
            if FileManager.default.fileExists(atPath: url.path) {
                sendFile(at: url, contentType: "image/jpeg",
                         request: request, on: connection, keepAlive: keepAlive)
                return
            }
        }
        // Missing thumbnail (legacy asset, failed import) → render one on demand.
        if let url = cachedRendition(for: asset, maxPixel: 512) {
            sendFile(at: url, contentType: "image/jpeg",
                     request: request, on: connection, keepAlive: keepAlive)
        } else {
            respond(.text("Thumbnail unavailable", status: 404),
                    to: request, on: connection, keepAlive: keepAlive)
        }
    }

    private func servePreview(id: String, request: HTTPRequest,
                              on connection: NWConnection, keepAlive: Bool) {
        guard let asset = asset(for: id) else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        // Video has no still rendition — its lightbox plays `/original` in a
        // <video>, and the "preview" is just the poster frame (the import-time
        // thumbnail). Serve that and skip the ImageIO render attempt entirely.
        if asset.mediaType == .video {
            if let thumb = asset.thumbnail {
                let url = library.absoluteURL(forRelative: thumb)
                if FileManager.default.fileExists(atPath: url.path) {
                    sendFile(at: url, contentType: "image/jpeg",
                             request: request, on: connection, keepAlive: keepAlive)
                    return
                }
            }
            respond(.text("Preview unavailable", status: 404),
                    to: request, on: connection, keepAlive: keepAlive)
            return
        }
        // A browser-friendly JPEG at a generous size, regardless of whether the
        // original is HEIF / TIFF / RAW (which most browsers can't display).
        if let url = cachedRendition(for: asset, maxPixel: 2048) {
            sendFile(at: url, contentType: "image/jpeg",
                     request: request, on: connection, keepAlive: keepAlive)
            return
        }
        // Couldn't render the big preview — fall back to the thumbnail so the
        // lightbox shows *something*.
        if let thumb = asset.thumbnail {
            let url = library.absoluteURL(forRelative: thumb)
            if FileManager.default.fileExists(atPath: url.path) {
                sendFile(at: url, contentType: "image/jpeg",
                         request: request, on: connection, keepAlive: keepAlive)
                return
            }
        }
        respond(.text("Preview unavailable", status: 404),
                to: request, on: connection, keepAlive: keepAlive)
    }

    private func serveOriginal(id: String, request: HTTPRequest,
                               on connection: NWConnection, keepAlive: Bool) {
        guard let asset = asset(for: id) else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        let url = library.absoluteURL(forRelative: asset.primary)
        guard FileManager.default.fileExists(atPath: url.path) else {
            respond(.text("Original missing on disk", status: 404),
                    to: request, on: connection, keepAlive: keepAlive)
            return
        }
        let filename = (asset.primary as NSString).lastPathComponent
        // Videos are served inline (no Content-Disposition) so the lightbox
        // <video> can play them in place; stills keep the attachment-download
        // behavior so "Open original" saves the master file as before.
        let inline = (asset.mediaType == .video)
        sendFile(at: url,
                 contentType: Self.contentType(forExtension: (asset.primary as NSString).pathExtension),
                 request: request, on: connection, keepAlive: keepAlive,
                 downloadName: inline ? nil : filename)
    }

    /// Serve a Live Photo's motion `.mov` inline (so the lightbox can play it in
    /// a <video>). 404 for stills / videos that have no motion companion.
    private func serveMotion(id: String, request: HTTPRequest,
                             on connection: NWConnection, keepAlive: Bool) {
        guard let asset = asset(for: id), let motion = asset.motionPath else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        let url = library.absoluteURL(forRelative: motion)
        guard FileManager.default.fileExists(atPath: url.path) else {
            respond(.text("Motion clip missing on disk", status: 404),
                    to: request, on: connection, keepAlive: keepAlive)
            return
        }
        sendFile(at: url,
                 contentType: Self.contentType(forExtension: (motion as NSString).pathExtension),
                 request: request, on: connection, keepAlive: keepAlive)
    }

    private enum CompanionKind { case raw, sidecar }

    /// Serve a RAW companion or XMP/AAE sidecar, addressed by index as
    /// `/raw/<id>/<i>` or `/sidecar/<id>/<i>`. For a RAW shooter these *are*
    /// the originals — `/original` only returns the display master (the
    /// JPEG/HEIF the camera wrote next to the RAW). Always an attachment
    /// download (browsers can't render RAW anyway).
    private func serveCompanion(_ rest: String, kind: CompanionKind, request: HTTPRequest,
                                on connection: NWConnection, keepAlive: Bool) {
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = Int(parts[1]), let asset = asset(for: parts[0]) else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        let list = (kind == .raw) ? asset.raws : asset.sidecars
        guard index >= 0, index < list.count else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        let relative = list[index]
        let url = library.absoluteURL(forRelative: relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            respond(.text("File missing on disk", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }
        sendFile(at: url,
                 contentType: Self.contentType(forExtension: (relative as NSString).pathExtension),
                 request: request, on: connection, keepAlive: keepAlive,
                 downloadName: (relative as NSString).lastPathComponent)
    }

    /// Return a cached JPEG rendition of `asset` at `maxPixel` (longest edge),
    /// generating it under `Caches/web/` on first request. Generation goes
    /// through a uniquely-named temp file then an atomic move, so two concurrent
    /// requests for the same id can never serve a half-written JPEG.
    private func cachedRendition(for asset: Asset, maxPixel: Int) -> URL? {
        let fm = FileManager.default
        let dir = library.cachesDir.appendingPathComponent("web", isDirectory: true)
        let target = dir.appendingPathComponent("\(asset.id.uuidString.lowercased())-\(maxPixel).jpg")
        if fm.fileExists(atPath: target.path) { return target }

        let source = library.absoluteURL(forRelative: asset.primary)
        guard fm.fileExists(atPath: source.path) else { return nil }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }

        let tmp = dir.appendingPathComponent(
            "\(asset.id.uuidString.lowercased())-\(maxPixel).\(ProcessInfo.processInfo.globallyUniqueString).tmp")
        do {
            try ThumbnailService().generate(from: source, maxPixel: maxPixel, to: tmp)
            if fm.fileExists(atPath: target.path) {
                // Another request won the race; use its result.
                try? fm.removeItem(at: tmp)
                return target
            }
            do {
                try fm.moveItem(at: tmp, to: target)
            } catch {
                // Lost a tight race between the check and the move.
                try? fm.removeItem(at: tmp)
                return fm.fileExists(atPath: target.path) ? target : nil
            }
            return target
        } catch {
            try? fm.removeItem(at: tmp)
            return nil
        }
    }

    // MARK: - Sending

    /// Send an inline-body response (HTML/JSON/JPEG-preview/error), then either
    /// arm the next read (keep-alive) or close. HEAD requests get the head only.
    private func respond(_ response: HTTPResponse, to request: HTTPRequest?,
                         on connection: NWConnection, keepAlive: Bool) {
        let head = response.serializedHead(keepAlive: keepAlive)
        var blob = head
        if request?.method != "HEAD", let body = response.body {
            blob.append(body)
        }
        connection.send(content: blob, completion: .contentProcessed { [weak self] _ in
            if keepAlive { self?.receiveHead(on: connection, buffer: Data()) }
            else { connection.cancel() }
        })
    }

    /// Stream a file straight off disk in bounded chunks. Honors a single HTTP
    /// `Range` request with a `206 Partial Content` response — required for
    /// `<video>` playback + seeking in Safari, and a nice-to-have for resuming a
    /// big RAW download. A request with no Range header gets the whole file
    /// (`200`), but we always advertise `Accept-Ranges: bytes`.
    private func sendFile(at url: URL, contentType: String, request: HTTPRequest,
                          on connection: NWConnection, keepAlive: Bool,
                          downloadName: String? = nil) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let handle = try? FileHandle(forReadingFrom: url) else {
            respond(.text("Not Found", status: 404), to: request, on: connection, keepAlive: keepAlive)
            return
        }

        // Resolve the byte window: full file by default, or the requested range.
        var status = 200
        var start = 0
        var length = size
        var rangeHeaders: [(String, String)] = []
        if let rangeHeader = request.headers["range"],
           let r = Self.parseByteRange(rangeHeader, fileSize: size) {
            status = 206
            start = r.start
            length = r.length
            rangeHeaders.append(("Content-Range", "bytes \(r.start)-\(r.end)/\(size)"))
        }

        var headers: [(String, String)] = [
            ("Content-Type", contentType),
            ("Content-Length", "\(length)"),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "private, max-age=3600"),
        ]
        headers.append(contentsOf: rangeHeaders)
        if let name = downloadName {
            headers.append(("Content-Disposition", "attachment; filename=\"\(Self.sanitizeFilename(name))\""))
        }
        let head = HTTPResponse(status: status, headers: headers, body: nil)
            .serializedHead(keepAlive: keepAlive)

        if request.method == "HEAD" {
            try? handle.close()
            connection.send(content: head, completion: .contentProcessed { [weak self] _ in
                if keepAlive { self?.receiveHead(on: connection, buffer: Data()) }
                else { connection.cancel() }
            })
            return
        }

        // Non-throwing seek keeps us on the 10.15.0 floor (the throwing
        // `seek(toOffset:)` is 10.15.4+). A no-op when start == 0.
        if start > 0 { handle.seek(toFileOffset: UInt64(start)) }

        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self = self else { try? handle.close(); connection.cancel(); return }
            self.streamBody(handle: handle, remaining: length, on: connection, keepAlive: keepAlive)
        })
    }

    /// Stream `remaining` bytes from `handle` in chunks, then finish. `remaining`
    /// bounds a ranged (206) response to its window; for a whole-file (200) send
    /// it's the full size and we simply stop at EOF.
    private func streamBody(handle: FileHandle, remaining: Int,
                            on connection: NWConnection, keepAlive: Bool) {
        if remaining <= 0 {
            try? handle.close()
            if keepAlive { receiveHead(on: connection, buffer: Data()) }
            else { connection.cancel() }
            return
        }
        let chunk = handle.readData(ofLength: min(remaining, PlateWebServer.streamChunk))
        if chunk.isEmpty {
            try? handle.close()
            if keepAlive { receiveHead(on: connection, buffer: Data()) }
            else { connection.cancel() }
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self = self else { try? handle.close(); connection.cancel(); return }
            self.streamBody(handle: handle, remaining: remaining - chunk.count,
                            on: connection, keepAlive: keepAlive)
        })
    }

    /// Parse a single HTTP byte range against a known file size. Supports
    /// `bytes=START-END`, `bytes=START-` (to EOF), and `bytes=-N` (last N bytes).
    /// Returns nil for a malformed or unsatisfiable spec (caller falls back to a
    /// normal 200 full-file send). Only the first range of a comma list is used.
    static func parseByteRange(_ header: String, fileSize: Int) -> (start: Int, end: Int, length: Int)? {
        guard fileSize > 0 else { return nil }
        let lower = header.lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = lower.dropFirst("bytes=".count)
        let firstSpec = spec.split(separator: ",").first.map(String.init) ?? String(spec)
        let parts = firstSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        var start: Int
        var end: Int
        if startStr.isEmpty {
            // Suffix range: the last N bytes.
            guard let n = Int(endStr), n > 0 else { return nil }
            let count = min(n, fileSize)
            start = fileSize - count
            end = fileSize - 1
        } else {
            guard let s = Int(startStr), s >= 0 else { return nil }
            start = s
            if endStr.isEmpty {
                end = fileSize - 1
            } else {
                guard let e = Int(endStr) else { return nil }
                end = e
            }
        }
        if end >= fileSize { end = fileSize - 1 }
        guard start <= end, start < fileSize else { return nil }
        return (start, end, end - start + 1)
    }

    // MARK: - Helpers

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":         return "image/jpeg"
        case "png":                 return "image/png"
        case "heic", "heif", "hif": return "image/heic"
        case "tif", "tiff":         return "image/tiff"
        case "gif":                 return "image/gif"
        case "webp":                return "image/webp"
        case "dng":                 return "image/x-adobe-dng"
        case "mov":                 return "video/quicktime"
        case "mp4", "m4v", "hevc":  return "video/mp4"
        case "avi":                 return "video/x-msvideo"
        case "mkv":                 return "video/x-matroska"
        case "webm":                return "video/webm"
        case "mpg", "mpeg":         return "video/mpeg"
        case "3gp":                 return "video/3gpp"
        case "3g2":                 return "video/3gpp2"
        default:                    return "application/octet-stream"
        }
    }

    /// Keep a filename safe to drop inside a quoted `Content-Disposition` value:
    /// no quotes, no CR/LF (header-injection), no path separators.
    private static func sanitizeFilename(_ name: String) -> String {
        var out = name
        for bad in ["\"", "\\", "\r", "\n", "/"] {
            out = out.replacingOccurrences(of: bad, with: "_")
        }
        return out.isEmpty ? "download" : out
    }
}
