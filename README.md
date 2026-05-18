# Plate

Native macOS photo library for Hasselblad RAW (3FR / FFF) and modern HEIF/JPEG, designed for photographers Apple Photos can't ingest. Same-dir same-basename pairing folds HEIC + RAW into one asset; the SQLite-backed library bundle (`.plate`) is rescue-friendly (`Originals/yyyy/yyyy-MM-dd/` on disk, no opaque blobs).

- Swift + AppKit, macOS 10.15+
- No external dependencies — ImageIO, CryptoKit, SQLite3 are all system frameworks
- `.plate` bundle: `Originals/`, `Caches/thumbs/`, `library.db`
- Year / Month / All Photos browsing; Favorites; user-defined Albums; soft-delete with Recently Deleted

![App icon](Branding/logo-f-italic-p.svg)

## Building

```bash
# 1. PlateCore tests (pure SPM library, no Xcode needed)
swift test

# 2. PlateApp (AppKit shell — generates .xcodeproj via xcodegen)
brew install xcodegen
cd PlateApp
xcodegen generate
xcodebuild -project PlateApp.xcodeproj -scheme PlateApp -configuration Release build
```

Release builds land in `~/Library/Developer/Xcode/DerivedData/PlateApp-*/Build/Products/Release/Plate.app`.

## Layout

| Path | Role |
|------|------|
| `Sources/PlateCore/` | Library: store, pairer, scanner, EXIF reader, thumbnailer |
| `Sources/PlateCLI/` | `plate-cli` for ingest from terminal |
| `PlateApp/PlateApp/` | AppKit shell (windows, view controllers, menus) |
| `PlateApp/project.yml` | xcodegen manifest — single source of truth for the .xcodeproj |
| `Branding/` | Source SVGs + `scripts/build-icons.sh` regenerates `.icns` |
| `Tests/PlateCoreTests/` | XCTest cases for the library |

## CI

GitHub Actions on every push to `main` (and tags `v*`):

- `test-core` — `swift test` for PlateCore
- `build-debug` — verifies AppKit target compiles
- `build-release` — produces `Plate.zip` as a workflow artifact (90-day retention); attaches it to a GitHub Release when a `v*` tag is pushed

## License

MIT — see [LICENSE](LICENSE).
