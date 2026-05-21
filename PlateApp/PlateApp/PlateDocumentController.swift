import AppKit
import PlateCore

/// Overrides the "New" flow so that creating a Plate library asks for a location
/// up-front (a `.plate` bundle must exist on disk before NSDocument can open it).
final class PlateDocumentController: NSDocumentController {

    /// Single-library model (like Photos / Lightroom): at most one `.plate` is
    /// open at a time. Opening or creating a *different* library first closes the
    /// current one; re-opening the library that's already open falls through to
    /// super, which just resurfaces its existing window (URL de-dupe). No save
    /// prompt — the bundle is the canonical store and every edit is already
    /// persisted, so closing the previous library loses nothing.
    ///
    /// Every open path funnels here (File ▸ Open, File ▸ New, Open Recent, the
    /// welcome window, Finder double-click via Apple Event, and launch auto-open),
    /// so this single override is the chokepoint that prevents multiple libraries
    /// being open simultaneously.
    override func openDocument(withContentsOf url: URL,
                              display displayDocument: Bool,
                              completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let target = url.standardizedFileURL
        for doc in documents where doc.fileURL?.standardizedFileURL != target {
            doc.close()
        }
        super.openDocument(withContentsOf: url,
                           display: displayDocument,
                           completionHandler: completionHandler)
    }

    override func newDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New Plate Library"
        panel.message = "Choose where to create your new Plate library."
        panel.nameFieldStringValue = "My Library.plate"
        panel.allowedFileTypes = ["plate"]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self = self else { return }
            do {
                _ = try PlateLibrary.create(at: url)
                self.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error = error {
                        NSAlert(error: error).runModal()
                    }
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
