import Foundation
import PlateCore

enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)
    case usage

    var description: String {
        switch self {
        case .missingArgument(let what): return "Missing argument: \(what)"
        case .usage: return "Usage error"
        }
    }
}

func usage() {
    let text = """
    plate-cli — Plate photo library command line

    Usage:
      plate-cli init <Library.plate>
      plate-cli import <Library.plate> <source>...
      plate-cli list <Library.plate>

    `source` may be a file or a directory (scanned recursively for supported formats).
    Same-directory same-basename files are folded into a single asset.
    """
    print(text)
}

func cmdInit(_ args: [String]) throws {
    guard let path = args.first else { throw CLIError.missingArgument("library path") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let lib = try PlateLibrary.create(at: url)
    print("Created \(lib.url.path)")
}

func cmdImport(_ args: [String]) throws {
    guard let libPath = args.first else { throw CLIError.missingArgument("library path") }
    let sources = Array(args.dropFirst())
    guard !sources.isEmpty else { throw CLIError.missingArgument("source path(s)") }

    let lib = try PlateLibrary.open(at: URL(fileURLWithPath: libPath).standardizedFileURL)

    var files: [URL] = []
    for raw in sources {
        let srcURL = URL(fileURLWithPath: raw).standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            files.append(contentsOf: try LibraryScanner.scan(directory: srcURL))
        } else {
            files.append(srcURL)
        }
    }

    let pairs = AssetPairer.pair(files: files)
    print("Scanned \(files.count) file(s) → \(pairs.count) asset(s) after pairing")

    let result = try lib.importPairs(pairs)
    print("Imported \(result.imported.count) asset(s)")
    for a in result.imported {
        let raws = a.raws.isEmpty ? "" : "  [+\(a.raws.count) RAW]"
        print("  \(a.id.uuidString.prefix(8))  \(a.primary)\(raws)")
    }
    if !result.duplicates.isEmpty {
        print("Skipped \(result.duplicates.count) duplicate(s):")
        for (url, existing) in result.duplicates {
            print("  \(url.lastPathComponent) — already in library as \(existing.primary)")
        }
    }
    if !result.failures.isEmpty {
        print("Failed \(result.failures.count) file(s):")
        for (url, err) in result.failures {
            print("  \(url.lastPathComponent) — \(err)")
        }
    }
}

func cmdList(_ args: [String]) throws {
    guard let libPath = args.first else { throw CLIError.missingArgument("library path") }
    let lib = try PlateLibrary.open(at: URL(fileURLWithPath: libPath).standardizedFileURL)
    print("Library: \(lib.url.path)")
    print("Assets : \(lib.manifest.assets.count)")
    let isoFmt = ISO8601DateFormatter()
    for a in lib.manifest.assets {
        let when = a.capturedAt.map { isoFmt.string(from: $0) } ?? "?"
        let raws = a.raws.isEmpty ? "" : "  [+\(a.raws.count) RAW]"
        print("  \(a.id.uuidString.prefix(8))  \(when)  \(a.primary)\(raws)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

do {
    switch args.first {
    case "init":
        try cmdInit(Array(args.dropFirst()))
    case "import":
        try cmdImport(Array(args.dropFirst()))
    case "list":
        try cmdList(Array(args.dropFirst()))
    case "help", "--help", "-h", .none:
        usage()
    case .some(let cmd):
        FileHandle.standardError.write(Data("Unknown command: \(cmd)\n".utf8))
        usage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
