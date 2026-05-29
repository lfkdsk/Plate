import Foundation

/// Lightweight in-app update check against the GitHub Releases API.
///
/// Deliberately minimal (no Sparkle, no auto-install): it fetches the latest
/// published release, compares its tag to the running version, and — if newer —
/// hands back a `Release` the UI can offer to open in the browser. The user
/// downloads + installs manually.
///
/// The two tricky-and-testable pieces live here as pure functions:
///   • `SemanticVersion` parsing + comparison (so "0.10.0" > "0.9.0", and a
///     leading "v" / build suffix doesn't break ordering), and
///   • `parseLatestRelease` (decoding the GitHub JSON payload).
/// The network call is isolated in `check(...)` behind an injectable fetcher so
/// tests never touch the network.
public enum UpdateChecker {

    // MARK: - Version

    /// A dotted numeric version (major.minor.patch), tolerant of a leading "v"
    /// and any trailing pre-release / build suffix ("1.2.0-beta" → 1.2.0).
    /// Missing components default to 0, so "1" == "1.0.0".
    public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        /// Parse "v1.2.3", "1.2", "1.2.3-beta.1", "  1.0.0 " → version, or nil
        /// when there's no leading numeric component at all.
        public init?(_ raw: String) {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            // Drop any pre-release / build metadata after the numeric core.
            if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
                s = String(s[..<cut])
            }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard let first = parts.first, let maj = Int(first) else { return nil }
            func comp(_ i: Int) -> Int {
                guard i < parts.count, let v = Int(parts[i]) else { return 0 }
                return v
            }
            self.major = maj
            self.minor = comp(1)
            self.patch = comp(2)
        }

        public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }

        public var description: String { "\(major).\(minor).\(patch)" }
    }

    // MARK: - Release

    /// A published GitHub release, distilled to what the updater needs.
    public struct Release: Equatable {
        public let version: SemanticVersion
        /// The raw tag as published, e.g. "v0.2.0" — shown to the user verbatim.
        public let tagName: String
        /// Human-facing release page (html_url) to open in the browser.
        public let htmlURL: URL
        /// Release notes body (may be empty).
        public let notes: String

        public init(version: SemanticVersion, tagName: String, htmlURL: URL, notes: String) {
            self.version = version
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.notes = notes
        }
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case badResponse
        case decoding(String)
        case network(String)

        public var description: String {
            switch self {
            case .badResponse:        return "Unexpected response from GitHub."
            case .decoding(let m):    return "Couldn't read release info: \(m)"
            case .network(let m):     return "Couldn't reach GitHub: \(m)"
            }
        }
    }

    /// GitHub "latest release" endpoint for a given owner/repo. `latest` excludes
    /// drafts and pre-releases — exactly what we want for stable update prompts.
    public static func latestReleaseURL(owner: String, repo: String) -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    // MARK: - Pure parsing

    /// Decode the GitHub "latest release" JSON payload into a `Release`.
    /// Pure + synchronous so it's unit-testable with a fixture string.
    public static func parseLatestRelease(_ data: Data) throws -> Release {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UpdateError.decoding(error.localizedDescription)
        }
        guard let dict = obj as? [String: Any] else {
            throw UpdateError.decoding("payload was not an object")
        }
        guard let tag = dict["tag_name"] as? String else {
            throw UpdateError.decoding("missing tag_name")
        }
        guard let version = SemanticVersion(tag) else {
            throw UpdateError.decoding("unparseable tag '\(tag)'")
        }
        let urlString = (dict["html_url"] as? String) ?? ""
        guard let html = URL(string: urlString) else {
            throw UpdateError.decoding("missing/invalid html_url")
        }
        let notes = (dict["body"] as? String) ?? ""
        return Release(version: version, tagName: tag, htmlURL: html, notes: notes)
    }

    /// Decide whether `latest` is an upgrade over `current`. Pure comparison —
    /// returns the release only when strictly newer, else nil.
    public static func upgrade(from current: SemanticVersion, to latest: Release) -> Release? {
        latest.version > current ? latest : nil
    }

    // MARK: - Network (injectable)

    /// Fetch + parse the latest release, then compare against `currentVersion`.
    /// Returns a `Release` only if it's strictly newer; nil if up to date.
    ///
    /// `fetch` is injectable so tests supply a canned payload — in production it
    /// defaults to a plain `URLSession` data task. Runs its completion on an
    /// arbitrary queue; callers hop to main for UI.
    public static func check(
        owner: String,
        repo: String,
        currentVersion: String,
        fetch: @escaping (URL, @escaping (Result<Data, Error>) -> Void) -> Void = UpdateChecker.defaultFetch,
        completion: @escaping (Result<Release?, Error>) -> Void
    ) {
        guard let current = SemanticVersion(currentVersion) else {
            completion(.failure(UpdateError.decoding("bad current version '\(currentVersion)'")))
            return
        }
        let url = latestReleaseURL(owner: owner, repo: repo)
        fetch(url) { result in
            switch result {
            case .failure(let e):
                completion(.failure(UpdateError.network(e.localizedDescription)))
            case .success(let data):
                do {
                    let release = try parseLatestRelease(data)
                    completion(.success(upgrade(from: current, to: release)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Default URLSession-backed fetcher with a GitHub-friendly Accept header and
    /// a short timeout (update checks must never block app launch).
    public static func defaultFetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Plate-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion(.failure(UpdateError.badResponse)); return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }
}
