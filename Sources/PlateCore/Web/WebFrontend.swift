import Foundation

/// The single-page gallery served at `/`. The markup itself lives in a real
/// `gallery.html` resource (inline CSS + vanilla JS, zero external requests so
/// it works over a tunnel with no CDN). This type just loads that file from the
/// bundle and injects the library name — no giant string literal in the source.
///
/// The page mirrors the native app: the justified row-packing layout from
/// `JustifiedGridLayout` and the `PlateTheme` palette. It reads photos from
/// `/api/assets`, lazy-loads `/thumb/<id>`, and opens a lightbox on
/// `/preview/<id>` with per-file download buttons (`/original`, `/raw/<id>/<i>`,
/// `/sidecar/<id>/<i>`). A `?key=` in the page URL is propagated onto every
/// subresource; otherwise the browser replays HTTP Basic credentials.
enum WebFrontend {

    /// The gallery page with the library name substituted into the title/header.
    static func html(libraryName: String) -> String {
        template.replacingOccurrences(of: "__LIBRARY_NAME__", with: escapeHTML(libraryName))
    }

    /// `gallery.html`, loaded once from the package resource bundle. Held static
    /// so we read + decode the file a single time rather than per request.
    private static let template: String = {
        guard let url = Bundle.module.url(forResource: "gallery", withExtension: "html"),
              let markup = try? String(contentsOf: url, encoding: .utf8) else {
            // Should never happen — the resource is bundled at build time. Serve
            // an obvious error rather than crashing the server thread.
            return "<!doctype html><meta charset=\"utf-8\"><title>Plate</title>"
                 + "<p>gallery.html resource is missing from the bundle.</p>"
        }
        return markup
    }()

    /// Minimal HTML-entity escape for the one piece of server-controlled text we
    /// interpolate (the library name in <title> and the header). `&` first so we
    /// don't double-escape the entities we introduce.
    private static func escapeHTML(_ string: String) -> String {
        var out = string
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}
