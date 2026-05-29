import AppKit
import PlateCore

/// Owns the single app-wide `PlateWebServer` instance.
///
/// Lives outside any window so the server keeps running after the config panel
/// closes, and so only one library is ever served at a time (one port). The
/// server holds a strong reference to the `PlateLibrary`, so its SQLite store
/// stays open and serving even if the user closes the document window.
final class WebServerCoordinator {
    static let shared = WebServerCoordinator()
    private init() {}

    private(set) var server: PlateWebServer?
    /// Display name of the library currently being served (for the panel's
    /// "Serving: …" line), so the user can tell *what* is exposed.
    private(set) var boundTitle: String?

    var isRunning: Bool { server?.isRunning ?? false }

    /// Start (or restart) the server bound to `library`. Any previously running
    /// server is stopped first — one library, one port at a time.
    func start(library: PlateLibrary, title: String,
               port: UInt16, token: String?, bindAllInterfaces: Bool) throws {
        stop()
        let configuration = PlateWebServer.Configuration(
            port: port, token: token, bindAllInterfaces: bindAllInterfaces)
        let server = PlateWebServer(library: library, configuration: configuration)
        try server.start()
        self.server = server
        self.boundTitle = title
    }

    func stop() {
        server?.stop()
        server = nil
        boundTitle = nil
    }

    /// Forget the cached asset index so freshly-imported photos appear without a
    /// restart. Called by the library window after an import completes.
    func reloadIfRunning() {
        server?.reload()
    }
}
