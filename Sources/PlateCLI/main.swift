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

/// A short tag for non-still assets in CLI listings: " [VIDEO 0:12]" / " [LIVE]".
func mediaTag(_ a: Asset) -> String {
    switch a.mediaType {
    case .image:
        return ""
    case .video:
        if let d = a.duration, d > 0 {
            let total = Int(d.rounded())
            return String(format: "  [VIDEO %d:%02d]", total / 60, total % 60)
        }
        return "  [VIDEO]"
    case .livePhoto:
        return "  [LIVE]"
    }
}

func usage() {
    let text = """
    plate-cli — Plate photo library command line

    Usage:
      plate-cli init <Library.plate>
      plate-cli import <Library.plate> <source>...
      plate-cli list <Library.plate>
      plate-cli serve <Library.plate> [--port N] [--token T | --no-auth] [--lan]

    `source` may be a file or a directory (scanned recursively for supported formats).
    Same-directory same-basename files are folded into a single asset.

    `serve` starts a read-only web gallery for the library:
      --port N      port to listen on (default 8080)
      --token T     require this shared secret (Basic auth password / ?key=)
      --no-auth     disable authentication (LAN only — never expose this)
      --lan         bind all interfaces so other devices can reach it directly
                    (default: loopback only, the safe pairing with a tunnel)
    With no --token and no --no-auth, a random token is generated and printed.
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
        print("  \(a.id.uuidString.prefix(8))  \(a.primary)\(raws)\(mediaTag(a))")
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
        print("  \(a.id.uuidString.prefix(8))  \(when)  \(a.primary)\(raws)\(mediaTag(a))")
    }
}

func cmdServe(_ args: [String]) throws {
    guard let libPath = args.first else { throw CLIError.missingArgument("library path") }

    var port: UInt16 = 8080
    var token: String?
    var explicitToken = false
    var noAuth = false
    var lan = false

    let rest = Array(args.dropFirst())
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--port", "-p":
            i += 1
            guard i < rest.count, let p = UInt16(rest[i]) else {
                throw CLIError.missingArgument("--port <number>")
            }
            port = p
        case "--token", "-t":
            i += 1
            guard i < rest.count else { throw CLIError.missingArgument("--token <secret>") }
            token = rest[i]
            explicitToken = true
        case "--no-auth":
            noAuth = true
        case "--lan":
            lan = true
        default:
            FileHandle.standardError.write(Data("Unknown option: \(rest[i])\n".utf8))
            throw CLIError.usage
        }
        i += 1
    }

    let lib = try PlateLibrary.open(at: URL(fileURLWithPath: libPath).standardizedFileURL)

    // Secure by default: with neither --token nor --no-auth, mint a random one
    // so the gallery is never accidentally wide open.
    let finalToken: String?
    if noAuth {
        finalToken = nil
    } else if explicitToken {
        finalToken = token
    } else {
        finalToken = PlateWebServer.generateToken()
    }

    let config = PlateWebServer.Configuration(port: port, token: finalToken, bindAllInterfaces: lan)
    let server = PlateWebServer(library: lib, configuration: config)
    try server.start()

    let name = lib.url.deletingPathExtension().lastPathComponent
    print("Plate web server — \(name)")
    print("  Photos:      \(lib.assetCount)")
    print("  Listening:   port \(port) — \(lan ? "all interfaces (LAN reachable)" : "loopback only (127.0.0.1)")")
    print("")
    if server.requiresAuth, let secret = finalToken {
        print("  Open locally: \(server.localURLWithToken)")
        print("  Access token: \(secret)")
        print("  (Browsers show a login prompt — leave the username blank, paste the token as the password.)")
    } else {
        print("  Open locally: \(server.localURL)")
        print("  WARNING: authentication is OFF — anyone who can reach this port sees every photo.")
    }
    if !lan {
        print("")
        print("  External access: point a Cloudflare Tunnel at http://127.0.0.1:\(port)")
    }
    print("")
    print("  Press Ctrl-C to stop.")

    // Block forever servicing connections on the listener's queue.
    RunLoop.main.run()
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
    case "serve":
        try cmdServe(Array(args.dropFirst()))
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
