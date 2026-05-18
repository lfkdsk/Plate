import AppKit
import PlateCore

/// Overrides the "New" flow so that creating a Plate library asks for a location
/// up-front (a `.plate` bundle must exist on disk before NSDocument can open it).
final class PlateDocumentController: NSDocumentController {

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
