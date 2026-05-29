import AppKit
import PlateCore

/// Standalone window hosting the library Statistics view. Auxiliary, not a
/// document window — opened from File ▸ Library Statistics… and owned (held
/// strong) by the LibraryWindowController so it persists between openings.
final class StatisticsWindowController: NSWindowController {

    init(library: PlateLibrary, libraryTitle: String) {
        let vc = StatisticsViewController(library: library)
        let window = NSWindow(contentViewController: vc)
        window.title = "Statistics — \(libraryTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.minSize = NSSize(width: 720, height: 480)
        // Auxiliary window: keep it around after close so re-opening is instant
        // and the owning controller's strong reference stays valid.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Recompute statistics from the current library state — called when the
    /// window is re-opened so it reflects imports / deletes / rebuilds since.
    func refresh() {
        (contentViewController as? StatisticsViewController)?.rebuild()
    }
}
