import Foundation
import SQLite3

/// SQLite-backed asset persistence for a Plate library. Replaces the
/// whole-file rewrite of `manifest.json` — incremental inserts, indexed
/// queries, no parse-everything-on-open at scale.
///
/// All access is serialised on an internal queue so callers can hit the store
/// from background threads (e.g. the import pipeline) without juggling
/// per-thread connections.
///
/// Schema is plain flat — `raws` / `sidecars` arrays go into JSON columns
/// (they're short and never queried as joins).
public final class AssetStore {

    public enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case migrationFailed(String)

        public var description: String {
            switch self {
            case .open(let m):              return "AssetStore open failed: \(m)"
            case .prepare(let m):           return "AssetStore prepare failed: \(m)"
            case .step(let m):              return "AssetStore step failed: \(m)"
            case .migrationFailed(let m):   return "AssetStore migration failed: \(m)"
            }
        }
    }

    private let url: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "plate.asset-store")

    /// Bumped when the schema changes. Stored in SQLite's `user_version` pragma.
    /// v1 → initial layout
    /// v2 → adds `content_hash` (SHA-256) for import dedup
    /// v3 → adds `is_favorite` + `deleted_at` columns on assets, plus the
    ///      `albums` / `album_assets` tables for user-defined collections.
    /// v4 → adds `position` to `albums` for user-defined sidebar ordering.
    /// v5 → adds EXIF shooting-metadata columns (camera_make/model, lens_model,
    ///      focal_length, aperture, shutter_speed, iso, latitude, longitude)
    ///      that power the Statistics view. Backfilled by "Rebuild Library Data".
    /// v6 → adds `media_type` (image/video/livePhoto), `motion_path` (a Live
    ///      Photo's paired .mov), and `duration` (video length, seconds) so the
    ///      library can hold movies and Live Photos alongside stills.
    public static let currentSchemaVersion: Int32 = 6

    public init(url: URL) throws {
        self.url = url
        try queue.sync { try openConnection() }
        try queue.sync { try createSchemaIfNeeded() }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Opening / schema

    private func openConnection() throws {
        var conn: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &conn, flags, nil)
        guard result == SQLITE_OK, let conn = conn else {
            let msg = conn.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code=\(result)"
            if let c = conn { sqlite3_close(c) }
            throw StoreError.open(msg)
        }
        self.db = conn
        // Better durability + write performance — WAL allows readers + one writer
        // and survives the typical "kill the app mid-write" scenario cleanly.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    private func createSchemaIfNeeded() throws {
        let existing = readUserVersion()
        if existing == 0 {
            // Fresh library: jump straight to the current schema (v3 — content_hash,
            // is_favorite, deleted_at baked in plus the album tables).
            try exec("""
                CREATE TABLE assets (
                    id            BLOB PRIMARY KEY NOT NULL,
                    primary_path  TEXT NOT NULL,
                    raws_json     TEXT NOT NULL DEFAULT '[]',
                    sidecars_json TEXT NOT NULL DEFAULT '[]',
                    captured_at   REAL,
                    pixel_width   INTEGER,
                    pixel_height  INTEGER,
                    thumbnail     TEXT,
                    content_hash  TEXT,
                    is_favorite   INTEGER NOT NULL DEFAULT 0,
                    deleted_at    REAL,
                    camera_make   TEXT,
                    camera_model  TEXT,
                    lens_model    TEXT,
                    focal_length  REAL,
                    aperture      REAL,
                    shutter_speed REAL,
                    iso           INTEGER,
                    latitude      REAL,
                    longitude     REAL,
                    media_type    TEXT NOT NULL DEFAULT 'image',
                    motion_path   TEXT,
                    duration      REAL,
                    created_at    REAL NOT NULL DEFAULT (julianday('now'))
                );
                CREATE INDEX idx_assets_captured     ON assets(captured_at DESC);
                CREATE INDEX idx_assets_primary      ON assets(primary_path);
                CREATE INDEX idx_assets_content_hash ON assets(content_hash);
                CREATE INDEX idx_assets_deleted_at   ON assets(deleted_at);

                CREATE TABLE albums (
                    id         BLOB PRIMARY KEY NOT NULL,
                    name       TEXT NOT NULL,
                    created_at REAL NOT NULL DEFAULT (julianday('now')),
                    position   INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_albums_name ON albums(name);
                CREATE INDEX idx_albums_position ON albums(position);

                CREATE TABLE album_assets (
                    album_id BLOB NOT NULL,
                    asset_id BLOB NOT NULL,
                    added_at REAL NOT NULL DEFAULT (julianday('now')),
                    PRIMARY KEY(album_id, asset_id),
                    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
                    FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
                );
                CREATE INDEX idx_album_assets_album ON album_assets(album_id);
                CREATE INDEX idx_album_assets_asset ON album_assets(asset_id);
            """)
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        } else if existing == 1 {
            // Upgrade chain: v1 → v2 → v3. Run each step in order so a stale-v1
            // library lands on v3 in a single open. SQLite ALTER TABLE within a
            // transaction is fine; each step is committed separately because
            // ALTER + PRAGMA user_version need to be visible to subsequent steps.
            try migrateV1toV2()
            try migrateV2toV3()
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
        } else if existing == 2 {
            try migrateV2toV3()
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
        } else if existing == 3 {
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
        } else if existing == 4 {
            try migrateV4toV5()
            try migrateV5toV6()
        } else if existing == 5 {
            try migrateV5toV6()
        } else if existing == Self.currentSchemaVersion {
            // Up to date.
        } else {
            throw StoreError.migrationFailed("library was written by a newer Plate (schema v\(existing))")
        }
    }

    private func migrateV1toV2() throws {
        // v1 → v2: add the content_hash column + index. Existing rows get
        // NULL hash (they won't participate in dedup until re-hashed).
        try exec("""
            ALTER TABLE assets ADD COLUMN content_hash TEXT;
            CREATE INDEX IF NOT EXISTS idx_assets_content_hash ON assets(content_hash);
        """)
        try exec("PRAGMA user_version = 2;")
    }

    private func migrateV2toV3() throws {
        // v2 → v3: favorites + soft-delete columns on assets, plus the album
        // tables. ALTER TABLE doesn't accept multiple ADD COLUMN clauses in one
        // statement on older SQLite versions shipped with macOS, so split them.
        try exec("ALTER TABLE assets ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
        try exec("ALTER TABLE assets ADD COLUMN deleted_at REAL;")
        try exec("CREATE INDEX IF NOT EXISTS idx_assets_deleted_at ON assets(deleted_at);")
        try exec("""
            CREATE TABLE IF NOT EXISTS albums (
                id         BLOB PRIMARY KEY NOT NULL,
                name       TEXT NOT NULL,
                created_at REAL NOT NULL DEFAULT (julianday('now'))
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_albums_name ON albums(name);")
        try exec("""
            CREATE TABLE IF NOT EXISTS album_assets (
                album_id BLOB NOT NULL,
                asset_id BLOB NOT NULL,
                added_at REAL NOT NULL DEFAULT (julianday('now')),
                PRIMARY KEY(album_id, asset_id),
                FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
                FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_album_assets_album ON album_assets(album_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_album_assets_asset ON album_assets(asset_id);")
        try exec("PRAGMA user_version = 3;")
    }

    private func migrateV3toV4() throws {
        // v3 → v4: user-defined album order. Add `position` and seed it from the
        // existing name order so the sidebar looks unchanged until the user drags
        // a row. Each album gets a distinct position = number of albums sorting
        // before it (ties broken by id), giving a stable 0..n-1 sequence.
        try exec("ALTER TABLE albums ADD COLUMN position INTEGER NOT NULL DEFAULT 0;")
        try exec("""
            UPDATE albums SET position = (
                SELECT COUNT(*) FROM albums b
                WHERE b.name < albums.name
                   OR (b.name = albums.name AND b.id < albums.id)
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_albums_position ON albums(position);")
        try exec("PRAGMA user_version = 4;")
    }

    private func migrateV4toV5() throws {
        // v4 → v5: EXIF shooting-metadata columns. Existing rows get NULLs until
        // the user runs "Rebuild Library Data", which re-extracts EXIF from the
        // originals on disk. One ADD COLUMN per statement — older SQLite shipped
        // with macOS rejects multiple ADD COLUMN clauses in a single ALTER.
        try exec("ALTER TABLE assets ADD COLUMN camera_make   TEXT;")
        try exec("ALTER TABLE assets ADD COLUMN camera_model  TEXT;")
        try exec("ALTER TABLE assets ADD COLUMN lens_model    TEXT;")
        try exec("ALTER TABLE assets ADD COLUMN focal_length  REAL;")
        try exec("ALTER TABLE assets ADD COLUMN aperture      REAL;")
        try exec("ALTER TABLE assets ADD COLUMN shutter_speed REAL;")
        try exec("ALTER TABLE assets ADD COLUMN iso           INTEGER;")
        try exec("ALTER TABLE assets ADD COLUMN latitude      REAL;")
        try exec("ALTER TABLE assets ADD COLUMN longitude     REAL;")
        try exec("PRAGMA user_version = 5;")
    }

    private func migrateV5toV6() throws {
        // v5 → v6: media-type columns. Existing rows are all stills, so the
        // NOT NULL DEFAULT 'image' backfills them correctly; motion_path /
        // duration stay NULL (no Live Photos or videos predate this column).
        // One ADD COLUMN per statement — older macOS SQLite rejects multiple
        // ADD COLUMN clauses in a single ALTER.
        try exec("ALTER TABLE assets ADD COLUMN media_type  TEXT NOT NULL DEFAULT 'image';")
        try exec("ALTER TABLE assets ADD COLUMN motion_path TEXT;")
        try exec("ALTER TABLE assets ADD COLUMN duration    REAL;")
        try exec("PRAGMA user_version = 6;")
    }

    private func readUserVersion() -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Public API

    public func insert(_ asset: Asset) throws {
        try queue.sync { try insertLocked(asset) }
    }

    /// Bulk-insert in a single transaction. Reports `(completed, total)` after
    /// every row when `progress` is provided — callers should hop to the main
    /// queue if updating UI.
    @discardableResult
    public func bulkInsert(_ assets: [Asset],
                           progress: ((Int, Int) -> Void)? = nil) throws -> Int
    {
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            var inserted = 0
            do {
                for (i, asset) in assets.enumerated() {
                    try insertLocked(asset)
                    inserted += 1
                    progress?(i + 1, assets.count)
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            return inserted
        }
    }

    /// Permanently delete a batch of asset rows by id (single transaction).
    /// This is the row-removal primitive; soft delete goes through
    /// `softDeleteAssets(ids:)` instead and leaves rows in place.
    public func permanentlyDeleteAssets(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var stmt: OpaquePointer?
                try prepare("DELETE FROM assets WHERE id = ?;", &stmt)
                defer { sqlite3_finalize(stmt) }
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindUUID(stmt, 1, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Soft-delete: stamp `deleted_at = julianday('now')` so the row vanishes
    /// from the main grid but stays around for restore. Single transaction.
    public func softDeleteAssets(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var stmt: OpaquePointer?
                try prepare("UPDATE assets SET deleted_at = julianday('now') WHERE id = ?;", &stmt)
                defer { sqlite3_finalize(stmt) }
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindUUID(stmt, 1, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Restore: clear `deleted_at` so the asset rejoins the main grid.
    public func restoreAssets(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var stmt: OpaquePointer?
                try prepare("UPDATE assets SET deleted_at = NULL WHERE id = ?;", &stmt)
                defer { sqlite3_finalize(stmt) }
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindUUID(stmt, 1, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Toggle the favorite flag on a single asset.
    public func setFavorite(assetID: UUID, isFavorite: Bool) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("UPDATE assets SET is_favorite = ? WHERE id = ?;", &stmt)
            defer { sqlite3_finalize(stmt) }
            try check(sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0))
            try bindUUID(stmt, 2, assetID)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.step(lastError())
            }
        }
    }

    /// Refresh the derived metadata on a row — captured-at, dimensions,
    /// thumbnail path, content hash. Used by the library's "Rebuild Library
    /// Data" operation which re-extracts EXIF + recomputes hashes + regenerates
    /// thumbnails for every asset. Doesn't touch favorite / deleted / file
    /// paths — those are user/import-time state, not derived data.
    public func updateAssetMetadata(id: UUID,
                                    capturedAt: Date?,
                                    pixelWidth: Int?,
                                    pixelHeight: Int?,
                                    thumbnail: String?,
                                    contentHash: String?,
                                    cameraMake: String?,
                                    cameraModel: String?,
                                    lensModel: String?,
                                    focalLength: Double?,
                                    aperture: Double?,
                                    shutterSpeed: Double?,
                                    iso: Int?,
                                    latitude: Double?,
                                    longitude: Double?,
                                    duration: Double?) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                UPDATE assets
                   SET captured_at = ?,
                       pixel_width = ?,
                       pixel_height = ?,
                       thumbnail = ?,
                       content_hash = ?,
                       camera_make = ?,
                       camera_model = ?,
                       lens_model = ?,
                       focal_length = ?,
                       aperture = ?,
                       shutter_speed = ?,
                       iso = ?,
                       latitude = ?,
                       longitude = ?,
                       duration = ?
                 WHERE id = ?;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            if let date = capturedAt {
                try check(sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970))
            } else {
                try check(sqlite3_bind_null(stmt, 1))
            }
            try bindOptionalInt(stmt, 2, pixelWidth)
            try bindOptionalInt(stmt, 3, pixelHeight)
            if let t = thumbnail {
                try bindText(stmt, 4, t)
            } else {
                try check(sqlite3_bind_null(stmt, 4))
            }
            if let h = contentHash {
                try bindText(stmt, 5, h)
            } else {
                try check(sqlite3_bind_null(stmt, 5))
            }
            try bindOptionalText(stmt, 6, cameraMake)
            try bindOptionalText(stmt, 7, cameraModel)
            try bindOptionalText(stmt, 8, lensModel)
            try bindOptionalDouble(stmt, 9, focalLength)
            try bindOptionalDouble(stmt, 10, aperture)
            try bindOptionalDouble(stmt, 11, shutterSpeed)
            try bindOptionalInt(stmt, 12, iso)
            try bindOptionalDouble(stmt, 13, latitude)
            try bindOptionalDouble(stmt, 14, longitude)
            try bindOptionalDouble(stmt, 15, duration)
            try bindUUID(stmt, 16, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.step(lastError())
            }
        }
    }

    /// All assets including soft-deleted ones, newest captured first. Used by
    /// rebuild operations — we want to refresh thumbnails for trashed photos
    /// too in case the user restores them later.
    public func allAssetsIncludingDeleted() throws -> [Asset] {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                ORDER BY (captured_at IS NULL), captured_at DESC, primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    public func count() throws -> Int {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("SELECT COUNT(*) FROM assets;", &stmt)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// All non-deleted assets, sorted by capture date descending (NULL last).
    /// The library's UI consumes this directly today; soft-deleted rows are
    /// filtered out at the query level so callers don't have to sieve.
    public func allAssetsCapturedDesc() throws -> [Asset] {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                WHERE deleted_at IS NULL
                ORDER BY (captured_at IS NULL), captured_at DESC, primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    /// Non-deleted assets matching a compiled SmartFilter predicate, newest
    /// capture first. The user predicate is ANDed with `deleted_at IS NULL` so
    /// trashed rows never leak into a filtered grid. An empty predicate degrades
    /// to the same query as `allAssetsCapturedDesc()`. All values arrive as
    /// bound parameters — the SQL text itself contains no user input.
    public func assets(matching compiled: SmartFilter.Compiled) throws -> [Asset] {
        try queue.sync {
            let whereClause = compiled.isEmpty
                ? "deleted_at IS NULL"
                : "deleted_at IS NULL AND \(compiled.whereSQL)"
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                WHERE \(whereClause)
                ORDER BY (captured_at IS NULL), captured_at DESC, primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            // Bind in left-to-right ? order (1-based).
            var index: Int32 = 1
            for binding in compiled.bindings {
                switch binding {
                case .text(let s):   try bindText(stmt, index, s)
                case .int(let i):    try check(sqlite3_bind_int64(stmt, index, i))
                case .double(let d): try check(sqlite3_bind_double(stmt, index, d))
                }
                index += 1
            }

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    /// Distinct non-null values of a text column among non-deleted assets,
    /// alphabetised (NOCASE). Used to populate filter dropdowns (cameras,
    /// lenses). `column` is a fixed allow-listed identifier — never user input.
    public func distinctTextValues(column: String) throws -> [String] {
        let allowed = ["camera_model", "camera_make", "lens_model"]
        guard allowed.contains(column) else { return [] }
        return try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                SELECT DISTINCT \(column) FROM assets
                WHERE \(column) IS NOT NULL AND \(column) <> '' AND deleted_at IS NULL
                ORDER BY \(column) COLLATE NOCASE;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            var values: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { values.append(String(cString: c)) }
            }
            return values
        }
    }

    /// Distinct capture years (Gregorian, local time) among non-deleted assets,
    /// most recent first. Used to populate the year filter.
    public func distinctCaptureYears() throws -> [Int] {
        try queue.sync {
            var stmt: OpaquePointer?
            // strftime needs a datetime; captured_at is epoch seconds → 'unixepoch'
            // with 'localtime' so the year matches the user's wall-clock.
            try prepare("""
                SELECT DISTINCT CAST(strftime('%Y', captured_at, 'unixepoch', 'localtime') AS INTEGER) AS y
                FROM assets
                WHERE captured_at IS NOT NULL AND deleted_at IS NULL
                ORDER BY y DESC;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            var years: [Int] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                years.append(Int(sqlite3_column_int(stmt, 0)))
            }
            return years
        }
    }

    /// Favorited, non-deleted assets — newest-first.
    public func favoriteAssetsCapturedDesc() throws -> [Asset] {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                WHERE is_favorite = 1 AND deleted_at IS NULL
                ORDER BY (captured_at IS NULL), captured_at DESC, primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    /// Soft-deleted assets, ordered by deletion time (most recently trashed first).
    public func recentlyDeletedAssetsCapturedDesc() throws -> [Asset] {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                WHERE deleted_at IS NOT NULL
                ORDER BY deleted_at DESC, primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    /// Look up an asset by its content hash — used for dedup on import.
    /// Returns nil if no row exists with that hash. Returns even soft-deleted
    /// rows so a freshly-trashed asset still blocks reimport (the user must
    /// either restore it or empty the trash to bring it back).
    public func findAsset(byContentHash hash: String) throws -> Asset? {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                WHERE content_hash = ?
                LIMIT 1;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, hash)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return try readAsset(from: stmt)
        }
    }

    /// Every non-null content hash in the library, including soft-deleted rows
    /// (so a trashed photo still reads as "already imported"). Used by the
    /// import picker to pre-flag candidates without a per-file DB round trip.
    public func allContentHashes() throws -> Set<String> {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("SELECT content_hash FROM assets WHERE content_hash IS NOT NULL;", &stmt)
            defer { sqlite3_finalize(stmt) }
            var hashes = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    hashes.insert(String(cString: c))
                }
            }
            return hashes
        }
    }

    // MARK: - Albums

    /// Create a new album and return its id.
    public func createAlbum(name: String) throws -> UUID {
        let id = UUID()
        try queue.sync {
            var stmt: OpaquePointer?
            // New albums append to the bottom of the user's order (Photos behavior).
            try prepare("""
                INSERT INTO albums (id, name, position)
                VALUES (?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM albums));
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindUUID(stmt, 1, id)
            try bindText(stmt, 2, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.step(lastError())
            }
        }
        return id
    }

    /// Persist a new album ordering. `orderedIDs` lists every album id in the
    /// desired display order; each row's `position` is rewritten to its index.
    /// Wrapped in a transaction so `listAlbums` never observes a half-applied
    /// order.
    public func setAlbumOrder(_ orderedIDs: [UUID]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                var stmt: OpaquePointer?
                try prepare("UPDATE albums SET position = ? WHERE id = ?;", &stmt)
                defer { sqlite3_finalize(stmt) }
                for (index, id) in orderedIDs.enumerated() {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, Int64(index))
                    try bindUUID(stmt, 2, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Delete an album. The `ON DELETE CASCADE` on `album_assets` clears
    /// membership rows automatically — the assets themselves are untouched.
    public func deleteAlbum(id: UUID) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("DELETE FROM albums WHERE id = ?;", &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindUUID(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.step(lastError())
            }
        }
    }

    public func renameAlbum(id: UUID, to newName: String) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("UPDATE albums SET name = ? WHERE id = ?;", &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, newName)
            try bindUUID(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.step(lastError())
            }
        }
    }

    /// All albums with a count of non-deleted member assets, alphabetised
    /// case-insensitively (NOCASE collation handles ASCII case folding;
    /// Hasselblad customers in CJK locales aren't well-served by this but
    /// neither is Photos.app's "Recents" — punt to v2 of the sidebar).
    public func listAlbums() throws -> [(id: UUID, name: String, assetCount: Int)] {
        try queue.sync {
            var stmt: OpaquePointer?
            try prepare("""
                SELECT a.id, a.name,
                       (SELECT COUNT(*) FROM album_assets aa
                        JOIN assets s ON s.id = aa.asset_id
                        WHERE aa.album_id = a.id AND s.deleted_at IS NULL) AS asset_count
                FROM albums a
                ORDER BY a.position ASC, a.name COLLATE NOCASE;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }

            var results: [(id: UUID, name: String, assetCount: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idLen = Int(sqlite3_column_bytes(stmt, 0))
                guard idLen == 16, let idPtr = sqlite3_column_blob(stmt, 0) else {
                    throw StoreError.step("malformed album id")
                }
                let uuid = idPtr.assumingMemoryBound(to: uuid_t.self).pointee
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let count = Int(sqlite3_column_int64(stmt, 2))
                results.append((id: UUID(uuid: uuid), name: name, assetCount: count))
            }
            return results
        }
    }

    /// Add assets to an album. `INSERT OR IGNORE` makes the call idempotent —
    /// re-adding an asset already in the album is a no-op rather than an error.
    public func addAssets(ids: [UUID], toAlbum albumID: UUID) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var stmt: OpaquePointer?
                try prepare("INSERT OR IGNORE INTO album_assets (album_id, asset_id) VALUES (?, ?);", &stmt)
                defer { sqlite3_finalize(stmt) }
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindUUID(stmt, 1, albumID)
                    try bindUUID(stmt, 2, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func removeAssets(ids: [UUID], fromAlbum albumID: UUID) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var stmt: OpaquePointer?
                try prepare("DELETE FROM album_assets WHERE album_id = ? AND asset_id = ?;", &stmt)
                defer { sqlite3_finalize(stmt) }
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindUUID(stmt, 1, albumID)
                    try bindUUID(stmt, 2, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw StoreError.step(lastError())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Members of an album that are not soft-deleted, newest capture first.
    public func assetsInAlbumCapturedDesc(id albumID: UUID) throws -> [Asset] {
        try queue.sync {
            var stmt: OpaquePointer?
            // Reuse the shared SELECT list (unqualified column names resolve to
            // `assets` — `album_assets` shares none of them) so column indices
            // stay in lockstep with readAsset across the EXIF schema additions.
            try prepare("""
                \(Self.assetSelectColumns)
                FROM assets
                JOIN album_assets aa ON aa.asset_id = assets.id
                WHERE aa.album_id = ? AND assets.deleted_at IS NULL
                ORDER BY (assets.captured_at IS NULL), assets.captured_at DESC, assets.primary_path;
                """, &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindUUID(stmt, 1, albumID)

            var results: [Asset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(try readAsset(from: stmt))
            }
            return results
        }
    }

    // MARK: - Internals

    /// Shared SELECT-list used by every read-side query so column indices in
    /// `readAsset(from:)` stay in lockstep across call sites.
    private static let assetSelectColumns = """
        SELECT id, primary_path, raws_json, sidecars_json,
               captured_at, pixel_width, pixel_height, thumbnail,
               content_hash, is_favorite, deleted_at,
               camera_make, camera_model, lens_model, focal_length,
               aperture, shutter_speed, iso, latitude, longitude,
               media_type, motion_path, duration
        """

    private func insertLocked(_ asset: Asset) throws {
        var stmt: OpaquePointer?
        try prepare("""
            INSERT INTO assets (id, primary_path, raws_json, sidecars_json,
                                captured_at, pixel_width, pixel_height, thumbnail,
                                content_hash, is_favorite, deleted_at,
                                camera_make, camera_model, lens_model, focal_length,
                                aperture, shutter_speed, iso, latitude, longitude,
                                media_type, motion_path, duration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindUUID(stmt, 1, asset.id)
        try bindText(stmt, 2, asset.primary)
        try bindText(stmt, 3, Self.encodeStringArray(asset.raws))
        try bindText(stmt, 4, Self.encodeStringArray(asset.sidecars))
        if let date = asset.capturedAt {
            try check(sqlite3_bind_double(stmt, 5, date.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(stmt, 5))
        }
        try bindOptionalInt(stmt, 6, asset.pixelWidth)
        try bindOptionalInt(stmt, 7, asset.pixelHeight)
        if let thumb = asset.thumbnail {
            try bindText(stmt, 8, thumb)
        } else {
            try check(sqlite3_bind_null(stmt, 8))
        }
        if let hash = asset.contentHash {
            try bindText(stmt, 9, hash)
        } else {
            try check(sqlite3_bind_null(stmt, 9))
        }
        try check(sqlite3_bind_int(stmt, 10, asset.isFavorite ? 1 : 0))
        if let deletedAt = asset.deletedAt {
            try check(sqlite3_bind_double(stmt, 11, deletedAt.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(stmt, 11))
        }
        try bindOptionalText(stmt, 12, asset.cameraMake)
        try bindOptionalText(stmt, 13, asset.cameraModel)
        try bindOptionalText(stmt, 14, asset.lensModel)
        try bindOptionalDouble(stmt, 15, asset.focalLength)
        try bindOptionalDouble(stmt, 16, asset.aperture)
        try bindOptionalDouble(stmt, 17, asset.shutterSpeed)
        try bindOptionalInt(stmt, 18, asset.iso)
        try bindOptionalDouble(stmt, 19, asset.latitude)
        try bindOptionalDouble(stmt, 20, asset.longitude)
        try bindText(stmt, 21, asset.mediaType.rawValue)
        try bindOptionalText(stmt, 22, asset.motionPath)
        try bindOptionalDouble(stmt, 23, asset.duration)

        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw StoreError.step(lastError())
        }
    }

    private func readAsset(from stmt: OpaquePointer?) throws -> Asset {
        guard let stmt = stmt else { throw StoreError.step("nil stmt") }

        // id (BLOB → UUID)
        let idLen = Int(sqlite3_column_bytes(stmt, 0))
        guard idLen == 16, let idPtr = sqlite3_column_blob(stmt, 0) else {
            throw StoreError.step("malformed id column")
        }
        let uuid = idPtr.assumingMemoryBound(to: uuid_t.self).pointee
        let id = UUID(uuid: uuid)

        let primary = String(cString: sqlite3_column_text(stmt, 1))
        let raws    = Self.decodeStringArray(String(cString: sqlite3_column_text(stmt, 2)))
        let sidecars = Self.decodeStringArray(String(cString: sqlite3_column_text(stmt, 3)))

        let capturedAt: Date? = (sqlite3_column_type(stmt, 4) == SQLITE_NULL)
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

        let pixelWidth:  Int? = (sqlite3_column_type(stmt, 5) == SQLITE_NULL) ? nil : Int(sqlite3_column_int64(stmt, 5))
        let pixelHeight: Int? = (sqlite3_column_type(stmt, 6) == SQLITE_NULL) ? nil : Int(sqlite3_column_int64(stmt, 6))

        let thumbnail: String? = (sqlite3_column_type(stmt, 7) == SQLITE_NULL)
            ? nil
            : String(cString: sqlite3_column_text(stmt, 7))

        let contentHash: String? = (sqlite3_column_type(stmt, 8) == SQLITE_NULL)
            ? nil
            : String(cString: sqlite3_column_text(stmt, 8))

        let isFavorite: Bool = sqlite3_column_int(stmt, 9) != 0

        let deletedAt: Date? = (sqlite3_column_type(stmt, 10) == SQLITE_NULL)
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        let cameraMake   = columnText(stmt, 11)
        let cameraModel  = columnText(stmt, 12)
        let lensModel    = columnText(stmt, 13)
        let focalLength  = columnDouble(stmt, 14)
        let aperture     = columnDouble(stmt, 15)
        let shutterSpeed = columnDouble(stmt, 16)
        let iso: Int?    = (sqlite3_column_type(stmt, 17) == SQLITE_NULL) ? nil : Int(sqlite3_column_int64(stmt, 17))
        let latitude     = columnDouble(stmt, 18)
        let longitude    = columnDouble(stmt, 19)

        let mediaType  = MediaType(storedValue: columnText(stmt, 20))
        let motionPath = columnText(stmt, 21)
        let duration   = columnDouble(stmt, 22)

        return Asset(id: id,
                     primary: primary,
                     raws: raws,
                     sidecars: sidecars,
                     capturedAt: capturedAt,
                     pixelWidth: pixelWidth,
                     pixelHeight: pixelHeight,
                     thumbnail: thumbnail,
                     contentHash: contentHash,
                     isFavorite: isFavorite,
                     deletedAt: deletedAt,
                     mediaType: mediaType,
                     motionPath: motionPath,
                     duration: duration,
                     cameraMake: cameraMake,
                     cameraModel: cameraModel,
                     lensModel: lensModel,
                     focalLength: focalLength,
                     aperture: aperture,
                     shutterSpeed: shutterSpeed,
                     iso: iso,
                     latitude: latitude,
                     longitude: longitude)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    // MARK: - Low-level helpers

    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastError())
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.step(lastError())
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(stmt, index, value, -1, Self.transient))
    }

    /// Bind a UUID as a 16-byte BLOB. Centralised so the byte layout (matching
    /// the storage format chosen by the original insert/delete paths) stays
    /// consistent across the new album/favorite/soft-delete code.
    private func bindUUID(_ stmt: OpaquePointer?, _ index: Int32, _ id: UUID) throws {
        let bytes = withUnsafeBytes(of: id.uuid) { Data($0) }
        try bytes.withUnsafeBytes { ptr in
            guard sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(ptr.count), Self.transient) == SQLITE_OK else {
                throw StoreError.step(lastError())
            }
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) throws {
        if let v = value {
            try check(sqlite3_bind_int64(stmt, index, Int64(v)))
        } else {
            try check(sqlite3_bind_null(stmt, index))
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) throws {
        if let v = value {
            try check(sqlite3_bind_double(stmt, index, v))
        } else {
            try check(sqlite3_bind_null(stmt, index))
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        if let v = value {
            try bindText(stmt, index, v)
        } else {
            try check(sqlite3_bind_null(stmt, index))
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw StoreError.step(lastError())
        }
    }

    private func lastError() -> String {
        guard let db = db else { return "(no connection)" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func encodeStringArray(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decodeStringArray(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
