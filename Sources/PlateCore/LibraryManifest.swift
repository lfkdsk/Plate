import Foundation

/// On-disk JSON manifest at `<Library.plate>/manifest.json`.
public struct LibraryManifest: Codable, Equatable {
    public var version: Int
    public var createdAt: Date
    public var assets: [Asset]

    public init(version: Int = LibraryManifest.currentVersion, createdAt: Date = Date(), assets: [Asset] = []) {
        self.version = version
        self.createdAt = createdAt
        self.assets = assets
    }

    public static let currentVersion: Int = 1
}

extension JSONEncoder {
    static var plateLibrary: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var plateLibrary: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
