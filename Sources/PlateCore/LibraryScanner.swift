import Foundation

public enum LibraryScanner {
    /// Walk a directory tree and return every regular file whose extension is recognized
    /// by `AssetKind`. Hidden files and packages are skipped.
    public static func scan(directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var results: [URL] = []
        let supported = AssetKind.allSupportedExtensions
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if supported.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results
    }
}
