import AppKit
import PlateCore

/// NSDocument backed by a `.plate` bundle on disk. The bundle is the canonical
/// store — every importPairs writes manifest.json atomically — so NSDocument's
/// in-memory dirty/save machinery is bypassed (no Save menu, no autosave).
final class PlateDocument: NSDocument {

    private(set) var library: PlateLibrary?

    /// Never let AppKit attempt to write us out — the bundle is always already saved.
    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }

    /// Always strip the `.plate` extension from the titlebar. The system would
    /// otherwise leak our internal package extension when the user has
    /// "Show all filename extensions" enabled in Finder — Apple Photos doesn't
    /// surface `.photoslibrary` either.
    override var displayName: String! {
        get {
            if let url = fileURL {
                return url.deletingPathExtension().lastPathComponent
            }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    override func makeWindowControllers() {
        let wc = LibraryWindowController(document: self)
        addWindowController(wc)
        // Apple-Event-driven open occasionally skips NSDocument's automatic
        // showWindows() — call it explicitly to be safe.
        wc.showWindow(self)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        self.library = try PlateLibrary.open(at: url)
    }

    /// `Save` / `Save As` / `Duplicate` are not meaningful for a Plate library —
    /// edits go through `PlateLibrary.importPairs`, which writes manifest.json
    /// atomically. We disable the menu items rather than implement a stub.
    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(duplicate(_:)),
             #selector(revertToSaved(_:)), #selector(runPageLayout(_:)):
            return false
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    func reloadLibrary() throws {
        guard let url = fileURL else { return }
        self.library = try PlateLibrary.open(at: url)
    }
}
