import AppKit
import PlateCore

final class LibraryWindowController: NSWindowController, NSToolbarDelegate, NSMenuDelegate, NSWindowDelegate {

    /// Backs Edit ▸ Undo / Redo (⌘Z / ⇧⌘Z). One manager per library window,
    /// vended to the responder chain via `windowWillReturnUndoManager(_:)`.
    /// LibraryViewController registers reversible edits (favorite / album /
    /// trash) here by reading `view.window?.undoManager`.
    let libraryUndoManager = UndoManager()

    private weak var libraryDocument: PlateDocument?
    /// Held strong so its scroll position / selection survive a detour through
    /// the detail viewer (which swaps the window's contentViewController).
    private var libraryViewController: LibraryViewController?
    private var sidebarViewController: SidebarViewController?
    /// Sidebar + library wrapped in an NSSplitViewController. This is the
    /// window's "default" content view; the detail viewer temporarily swaps it
    /// out and we restore it on exit.
    private var splitViewController: NSSplitViewController?
    private var detailViewController: DetailViewController?
    private weak var zoomSlider: NSSlider?
    private weak var progressSpinner: NSProgressIndicator?
    private weak var progressCountLabel: NSTextField?
    private weak var viewModeSegment: NSSegmentedControl?
    private weak var sortToolbarMenu: NSMenu?
    /// Held strong so the Statistics window survives between openings (and so
    /// re-opening reuses + refreshes it rather than stacking duplicates).
    private var statisticsWC: StatisticsWindowController?
    /// The read-only web-gallery config panel (Share ▸ Web Server…). Held so
    /// re-opening refocuses the same panel rather than stacking duplicates.
    private var webServerWC: WebServerWindowController?
    /// The smart-filter popover and the toolbar button it anchors to. The button
    /// reference lets us reflect active-filter state (filled icon) and re-anchor.
    private var filterPopover: NSPopover?
    private weak var filterButton: NSButton?

    init(document: PlateDocument) {
        self.libraryDocument = document

        // Default the library window to the full visible frame of the primary
        // screen (minus menu bar + dock) — photo browsing wants room, the old
        // 1280×820 centered default left an awkward black border around it.
        // Subsequent launches use macOS state restoration to keep whatever size
        // the user resized to.
        let screenVisible = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialFrame = screenVisible
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = document.displayName ?? "Plate Library"
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        window.minSize = NSSize(width: 640, height: 400)
        // Ensure double-click-titlebar / green button enters native fullscreen.
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Hide the generic white document proxy icon — it doesn't fit the
        // dark editorial palette and we don't need drag-the-document affordance.
        window.standardWindowButton(.documentIconButton)?.isHidden = true

        super.init(window: window)

        let vc = LibraryViewController()
        vc.library = document.library
        vc.onEnterDetail = { [weak self] index in self?.enterDetail(at: index) }
        vc.onImportPhase = { [weak self] phase in self?.applyImportPhase(phase) }
        vc.onDisplayModeChanged = { [weak self] mode in self?.syncViewModeSegment(mode) }
        vc.onAlbumsChanged = { [weak self] in self?.sidebarViewController?.refreshAlbums() }
        vc.onFilterChanged = { [weak self] filter in self?.updateFilterButton(active: !filter.isEmpty) }
        self.libraryViewController = vc

        // Sidebar — Library / Favorites / Recently Deleted / Albums.
        // Selecting an item flips the library's data source.
        let sidebar = SidebarViewController()
        sidebar.library = document.library
        sidebar.onSelectSource = { [weak self] source in
            self?.libraryViewController?.setSource(source)
        }
        // "+" button on the ALBUMS header → re-uses the same New Album dialog
        // as the File menu / right-click context menu (single source of truth).
        sidebar.onNewAlbumRequested = { [weak self] in
            self?.libraryViewController?.newAlbumFromMenu(nil)
        }
        self.sidebarViewController = sidebar

        // Wrap sidebar + library in an NSSplitViewController. The library
        // pane keeps the current toolbar / Back button / grid behavior; the
        // sidebar gets a translucent source-list look on macOS 11+ via
        // `sidebarWithViewController:`.
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .none
        }
        let libraryItem = NSSplitViewItem(viewController: vc)
        if #available(macOS 11.0, *) {
            libraryItem.titlebarSeparatorStyle = .automatic
        }
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(libraryItem)
        self.splitViewController = split

        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "PlateLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Force-centre the Year/Month/All Photos switcher. Two flanking
        // flexibleSpaces alone don't reliably centre it on macOS 11+ (the
        // trailing items pull it right); centeredItemIdentifier pins it to the
        // middle of the content region regardless. The flexes remain as the
        // 10.15 fallback where this property doesn't exist.
        if #available(macOS 11.0, *) {
            toolbar.centeredItemIdentifier = TID.viewMode
        }
        window.toolbar = toolbar

        // NSScreen.screens.first is the user-designated main display (the one with
        // the menu bar). NSScreen.main returns the screen with the *key* window,
        // which at init time can be a different screen than where the user is —
        // landing our window on a secondary display.
        let screen = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let centered = NSRect(
            x: screen.midX - initialFrame.width / 2,
            y: screen.midY - initialFrame.height / 2,
            width: initialFrame.width,
            height: initialFrame.height
        )
        window.setFrame(centered, display: false)

        // Become the window's delegate so we can vend `libraryUndoManager` to
        // the responder chain. We implement only windowWillReturnUndoManager —
        // all other NSWindowDelegate behavior stays at AppKit defaults.
        window.delegate = self

        // Photos-style auto-import: watch for camera / SD-card mounts.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        libraryUndoManager
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Toolbar actions

    @objc func importFromMenu(_ sender: Any?) { showImportPanel() }

    /// File → Rebuild Library Data… Re-extracts EXIF, dimensions, content
    /// hashes, and regenerates thumbnails for every asset. Originals on disk
    /// stay untouched. Favorites / albums / trash state are preserved.
    @objc func rebuildLibraryDataFromMenu(_ sender: Any?) {
        guard let library = libraryDocument?.library, let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rebuild library data?"
        alert.informativeText = """
            Re-reads every photo to refresh thumbnails, EXIF dates, dimensions \
            and content hashes. Originals on disk are untouched. Favorites, \
            albums, and Recently Deleted are preserved. Depending on library \
            size this may take a while.
            """
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runRebuild(library: library)
        }
    }

    private func runRebuild(library: PlateLibrary) {
        // Reuse the toolbar's import-progress spinner — same vocabulary
        // ("scanning" → "x/y" → "finished") so the user sees it animate the
        // same way a big import does.
        applyImportPhase(.scanning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try library.rebuildAllAssets(progress: { completed, total in
                    DispatchQueue.main.async {
                        self?.applyImportPhase(.progress(completed: completed, total: total))
                    }
                })
                DispatchQueue.main.async {
                    self?.applyImportPhase(.finished)
                    self?.libraryViewController?.reload()
                    WebServerCoordinator.shared.reloadIfRunning()
                    self?.presentRebuildSummary(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.applyImportPhase(.finished)
                    if let window = self?.window {
                        NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    private func presentRebuildSummary(_ result: PlateLibrary.RebuildResult) {
        let alert = NSAlert()
        let failed = result.failures.count
        if failed == 0 {
            alert.alertStyle = .informational
            alert.messageText = "Rebuilt \(result.rebuilt) photo\(result.rebuilt == 1 ? "" : "s")."
            alert.informativeText = "All thumbnails, dates and content hashes refreshed."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Rebuilt \(result.rebuilt), \(failed) failed."
            let preview = result.failures.prefix(5).map { failure -> String in
                let name = (failure.asset.primary as NSString).lastPathComponent
                return "  • \(name)"
            }.joined(separator: "\n")
            var body = "Couldn't refresh these — most likely the primary file was renamed or moved outside the library:\n\n" + preview
            if failed > 5 { body += "\n  … and \(failed - 5) more." }
            alert.informativeText = body
        }
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// File ▸ Library Statistics… Opens (or refreshes + refocuses) a window of
    /// static analysis over the active library — equipment, time-of-capture and
    /// daily-activity breakdowns.
    @objc func showStatisticsFromMenu(_ sender: Any?) {
        guard let library = libraryDocument?.library else { return }
        let title = libraryDocument?.displayName ?? "Library"
        if let wc = statisticsWC {
            wc.refresh()
        } else {
            statisticsWC = StatisticsWindowController(library: library, libraryTitle: title)
        }
        statisticsWC?.showWindow(self)
        statisticsWC?.window?.makeKeyAndOrderFront(self)
    }

    /// Share ▸ Web Server… — open (or refocus) the read-only web-gallery panel
    /// bound to this window's library. The panel itself drives start/stop and
    /// shows the address, password, and Cloudflare Tunnel hint.
    @objc func showWebServerFromMenu(_ sender: Any?) {
        guard let library = libraryDocument?.library else { return }
        let title = libraryDocument?.displayName ?? "Library"
        if let wc = webServerWC {
            wc.updateBinding(library: library, libraryTitle: title)
        } else {
            let wc = WebServerWindowController(library: library, libraryTitle: title)
            webServerWC = wc
            wc.window?.center()
        }
        webServerWC?.showWindow(self)
        webServerWC?.window?.makeKeyAndOrderFront(self)
    }

    /// Toolbar filter button → toggle the smart-filter popover anchored to it.
    @objc private func toggleFilterPopover(_ sender: Any?) {
        if let pop = filterPopover, pop.isShown {
            pop.performClose(sender)
            return
        }
        guard let library = libraryDocument?.library,
              let vc = libraryViewController,
              let anchor = filterButton else { return }

        let content = FilterPopoverViewController(
            cameras: library.distinctCameras,
            lenses: library.distinctLenses,
            years: library.distinctCaptureYears,
            current: vc.smartFilter
        )
        content.onChange = { [weak self] filter in
            self?.libraryViewController?.setSmartFilter(filter)
        }
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        filterPopover = pop
    }

    /// Reflect active-filter state on the toolbar button: a filled icon + accent
    /// tint when any rule is set, the outline icon when the filter is clear.
    private func updateFilterButton(active: Bool) {
        guard let button = filterButton else { return }
        let name = active ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle"
        button.image = symbol(name, fallback: NSImage.Name("NSListViewTemplate"))
        if #available(macOS 11.0, *) {
            button.contentTintColor = active ? PlateColor.accent : nil
        }
        button.toolTip = active ? "Filter active — click to edit or clear"
                                : "Filter photos by camera, lens, date and EXIF"
    }

    @objc func zoomIn(_ sender: Any?) {
        libraryViewController?.adjustRowHeight(by: +40)
        syncZoomSlider()
    }
    @objc func zoomOut(_ sender: Any?) {
        libraryViewController?.adjustRowHeight(by: -40)
        syncZoomSlider()
    }

    private func syncZoomSlider() {
        if let h = libraryViewController?.currentRowHeight {
            zoomSlider?.doubleValue = Double(h)
        }
    }

    // MARK: - Detail viewer swap

    /// Setting `window.contentViewController` causes the window to resize to the
    /// new view's `fittingSize`. The detail view contains an NSImageView whose
    /// intrinsic size is the underlying image's pixel dimensions (~100MP HEIC →
    /// huge), which would blow the window up. We snapshot the current frame
    /// before the swap and restore it immediately after.
    private func enterDetail(at index: Int) {
        guard let library = libraryDocument?.library,
              let vc = libraryViewController,
              !vc.assets.isEmpty,
              let window = window else { return }
        let savedFrame = window.frame
        let detail = DetailViewController(
            library: library,
            assets: vc.assets,
            startIndex: index
        ) { [weak self] in self?.exitDetail() }
        detail.onToggleFavorite = { [weak self] asset, newValue in
            self?.registerDetailFavoriteUndo(asset, newValue: newValue)
        }
        detailViewController = detail
        window.toolbar?.isVisible = false
        // System titlebar text would otherwise show through our custom overlay
        // (NSVisualEffectView in `.withinWindow` mode only blurs the window's
        // content; the titlebar is drawn outside that).
        window.titleVisibility = .hidden
        // NSDocument plants the proxy icon (small file representation) at the
        // center of the titlebar even when the title text is hidden. Hide that
        // button too so the detail view has a perfectly clean top edge.
        window.standardWindowButton(.documentIconButton)?.isHidden = true
        Self.applyContentTransition(on: window, duration: 0.28)
        window.contentViewController = detail
        window.setFrame(savedFrame, display: true)
        window.makeFirstResponder(detail)
    }

    /// Register the inverse of a favorite the detail viewer just wrote to the
    /// DB. The viewer is transient (gone on close) and the grid's own undo
    /// manager is nil while its view is off-window, so neither can own this —
    /// the window controller, which outlives both, does. We target the grid VC
    /// (persistent, and not the owner of this manager, so no retain cycle); its
    /// `favoriteAsset` reverts via the normal path (DB write + redo + reload).
    /// If the viewer is still up when ⌘Z fires, we also refresh its heart.
    private func registerDetailFavoriteUndo(_ asset: Asset, newValue: Bool) {
        guard let grid = libraryViewController else { return }
        let actionName = newValue ? "Favorite" : "Remove from Favorites"
        libraryUndoManager.registerUndo(withTarget: grid) { [weak self] grid in
            grid.favoriteAsset(asset, isFavorite: !newValue, actionName: actionName)
            self?.detailViewController?.reflectFavorite(assetID: asset.id, isFavorite: !newValue)
        }
        libraryUndoManager.setActionName(actionName)
    }

    private func exitDetail() {
        guard let split = splitViewController, let window = window else { return }
        // The grid holds a value-type snapshot taken when detail opened, so a
        // favorite toggled in the viewer isn't reflected there. Re-pull from the
        // DB on the way out (keeping scroll) when the viewer changed anything.
        let gridNeedsRefresh = detailViewController?.didMutateLibrary ?? false
        let savedFrame = window.frame
        Self.applyContentTransition(on: window, duration: 0.22)
        // Restore the sidebar+library split as the window's content — the
        // sidebar disappeared while we were in the immersive detail viewer.
        window.contentViewController = split
        window.setFrame(savedFrame, display: true)
        window.toolbar?.isVisible = true
        window.titleVisibility = .visible
        // Proxy icon stays hidden in the library window too (see init).
        detailViewController = nil
        if gridNeedsRefresh { libraryViewController?.reloadPreservingScroll() }
    }

    /// Drop a CATransition on the window's content layer just before swapping
    /// its subview. AppKit + Core Animation then crossfades the old subview
    /// out and the new one in over the requested duration — no manual snapshot
    /// or overlay required.
    private static func applyContentTransition(on window: NSWindow, duration: CFTimeInterval) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        contentView.layer?.add(transition, forKey: "PlateContentSwap")
    }

    @objc private func toolbarImport(_ sender: Any?)   { showImportPanel() }
    @objc private func toolbarZoomIn(_ sender: Any?)   { zoomIn(sender) }
    @objc private func toolbarZoomOut(_ sender: Any?)  { zoomOut(sender) }

    private func showImportPanel() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Import into Library"
        panel.message = "Pick files or folders — recognized images will be folded by basename."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK else { return }
            self?.libraryViewController?.importURLs(panel.urls)
        }
    }

    // MARK: - Camera / SD-card import

    /// A removable volume mounted. If it looks like a camera / SD card (has a
    /// DCIM folder), scan it and offer the import picker. Plain disks / disk
    /// images without DCIM are ignored so we don't nag on every mount.
    @objc private func volumeDidMount(_ note: Notification) {
        guard let url = (note.userInfo?["NSWorkspaceVolumeURLKey"] as? URL)
            ?? (note.userInfo?["NSDevicePath"] as? String).map({ URL(fileURLWithPath: $0) })
        else { return }
        var isDir: ObjCBool = false
        let dcim = url.appendingPathComponent("DCIM", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDir), isDir.boolValue
        else { return }
        scanAndPresentPicker(root: url, sourceName: url.lastPathComponent, announceEmpty: false)
    }

    /// File ▸ Import from Camera or Card… — manual entry point (also handy for
    /// importing from an ordinary folder).
    @objc func importFromCardFromMenu(_ sender: Any?) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Import from Camera or Card"
        panel.message = "Choose a camera, SD card, or folder to import from."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let root = panel.url else { return }
            self?.scanAndPresentPicker(root: root, sourceName: root.lastPathComponent, announceEmpty: true)
        }
    }

    /// Scan `root` (its DCIM subfolder when present, else the whole tree) for
    /// importable files off the main thread, pair them, and show the picker.
    private func scanAndPresentPicker(root: URL, sourceName: String, announceEmpty: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanRoot: URL = {
                var isDir: ObjCBool = false
                let dcim = root.appendingPathComponent("DCIM", isDirectory: true)
                if FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDir), isDir.boolValue {
                    return dcim
                }
                return root
            }()
            let files = (try? LibraryScanner.scan(directory: scanRoot)) ?? []
            let pairs = AssetPairer.pair(files: files)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !pairs.isEmpty else {
                    if announceEmpty { self.presentNoPhotosFound(sourceName: sourceName) }
                    return
                }
                guard let lib = self.libraryDocument?.library,
                      let presenter = self.window?.contentViewController else { return }
                ImportPickerViewController.present(
                    from: presenter,
                    library: lib,
                    pairs: pairs,
                    sourceName: sourceName
                ) { [weak self] in
                    self?.libraryViewController?.reload()
                    WebServerCoordinator.shared.reloadIfRunning()
                }
            }
        }
    }

    private func presentNoPhotosFound(sourceName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No importable photos found"
        alert.informativeText = "“\(sourceName)” doesn’t contain any recognized photo files."
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSToolbarDelegate

    private enum TID {
        static let zoom     = NSToolbarItem.Identifier("Plate.zoom")
        static let progress = NSToolbarItem.Identifier("Plate.progress")
        static let viewMode = NSToolbarItem.Identifier("Plate.viewMode")
        static let sort     = NSToolbarItem.Identifier("Plate.sort")
        static let stats    = NSToolbarItem.Identifier("Plate.stats")
        static let filter   = NSToolbarItem.Identifier("Plate.filter")
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] =
            [.toggleSidebar, TID.zoom, TID.progress, TID.viewMode, TID.sort, TID.filter, TID.stats, .flexibleSpace, .space]
        if #available(macOS 11.0, *) { ids.append(.sidebarTrackingSeparator) }
        return ids
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Photos-style single row:
        //   sidebar toggle (over the sidebar) ┊ sidebarTrackingSeparator ┊
        //   flex → viewMode (centred in the content pane) → flex →
        //   sort + zoom pinned to the trailing edge.
        //
        // The sidebarTrackingSeparator pins the toolbar's divider to the sidebar
        // split divider, so the toggle sits above the sidebar and the centring
        // flexes measure the *content* region — otherwise every control bunches
        // up on the right with dead space on the left. (11+ only; on 10.15 it's
        // omitted and AppKit falls back to a plain continuous bar.)
        //
        // A fixed `.space` separates sort from zoom so Tahoe renders them as two
        // distinct pills rather than fusing them into one rounded background.
        //
        // TID.progress is intentionally absent: Tahoe groups adjacent items into
        // one background, so a permanently-present (idle/empty) progress item
        // would leave dead space inside the zoom pill. It's inserted on demand
        // during import/rebuild and removed when finished (see applyImportPhase
        // / setProgressItemVisible).
        var ids: [NSToolbarItem.Identifier] = [.toggleSidebar]
        if #available(macOS 11.0, *) { ids.append(.sidebarTrackingSeparator) }
        ids += [.flexibleSpace, TID.viewMode, .flexibleSpace, TID.filter, TID.stats, TID.sort, .space, TID.zoom]
        return ids
    }

    func toolbar(_ t: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case TID.viewMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "View"
            item.paletteLabel = "View Mode"
            let seg = NSSegmentedControl(
                labels: ["Year", "Month", "All Photos"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(toolbarViewMode(_:))
            )
            seg.selectedSegment = 2
            seg.segmentDistribution = .fit
            seg.controlSize = .regular
            self.viewModeSegment = seg
            item.view = seg
            return item

        case TID.filter:
            // Smart-filter button — opens a popover of Photos-style EXIF rules.
            // Uses an NSButton as the item view so the popover can anchor to it;
            // the icon fills (line.3…decrease.circle.fill) when a filter is live.
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Filter"
            item.paletteLabel = "Filter"
            item.toolTip = "Filter photos by camera, lens, date and EXIF"
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.image = symbol("line.3.horizontal.decrease.circle",
                                  fallback: NSImage.Name("NSListViewTemplate"))
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggleFilterPopover(_:))
            self.filterButton = button
            item.view = button
            updateFilterButton(active: !(libraryViewController?.smartFilter.isEmpty ?? true))
            return item

        case TID.stats:
            // Library Statistics button — opens the static-analysis window
            // (same target as File ▸ Library Statistics… / ⌥⌘I). A plain icon
            // button keeps it visually quiet next to the Sort pull-down.
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Statistics"
            item.paletteLabel = "Library Statistics"
            item.toolTip = "Show library statistics"
            item.image = symbol("chart.bar.xaxis",
                                 fallback: NSImage.Name("NSListViewTemplate"))
            item.target = self
            item.action = #selector(showStatisticsFromMenu(_:))
            item.isBordered = true
            return item

        case TID.sort:
            // Pull-down with a sort glyph + chevron. Clicking pops the menu;
            // checkmarks are refreshed on open via menuNeedsUpdate so they
            // always mirror the library's current order (which the View ▸
            // Sort By menu can also change).
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Sort"
            item.paletteLabel = "Sort"
            item.toolTip = "Sort photos by capture date"
            item.image = symbol("arrow.up.arrow.down",
                                 fallback: NSImage.Name("NSListViewTemplate"))
            let menu = NSMenu()
            menu.delegate = self
            let newest = NSMenuItem(title: "Newest First",
                                    action: #selector(toolbarSort(_:)),
                                    keyEquivalent: "")
            newest.target = self
            newest.tag = 0
            let oldest = NSMenuItem(title: "Oldest First",
                                    action: #selector(toolbarSort(_:)),
                                    keyEquivalent: "")
            oldest.target = self
            oldest.tag = 1
            menu.addItem(newest)
            menu.addItem(oldest)
            item.menu = menu
            item.showsIndicator = true
            self.sortToolbarMenu = menu
            return item

        case TID.progress:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = ""
            item.paletteLabel = "Import Progress"
            item.toolTip = "Import progress"

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            // Auto-hide the spinner when stopped — toolbar slot collapses too.
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            self.progressSpinner = spinner

            let count = NSTextField(labelWithString: "")
            count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            count.textColor = PlateColor.textMuted
            count.alignment = .left
            count.isHidden = true
            count.translatesAutoresizingMaskIntoConstraints = false
            self.progressCountLabel = count

            let stack = NSStackView(views: [spinner, count])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = true
            stack.frame = NSRect(x: 0, y: 0, width: 100, height: 24)
            item.view = stack
            item.minSize = NSSize(width: 16, height: 24)
            item.maxSize = NSSize(width: 120, height: 24)
            return item

        case TID.zoom:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Zoom"
            item.paletteLabel = "Thumbnail Size"
            item.toolTip = "Drag to resize thumbnails"

            // Photos.app pattern: small `-` icon — continuous slider — `+` icon.
            let minIcon = NSImageView()
            minIcon.image = symbol("minus", fallback: NSImage.Name("NSRemoveTemplate"))
            minIcon.imageScaling = .scaleProportionallyDown
            minIcon.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 11.0, *) { minIcon.contentTintColor = PlateColor.textMuted }
            NSLayoutConstraint.activate([
                minIcon.widthAnchor.constraint(equalToConstant: 12),
                minIcon.heightAnchor.constraint(equalToConstant: 12),
            ])

            let maxIcon = NSImageView()
            maxIcon.image = symbol("plus", fallback: NSImage.Name("NSAddTemplate"))
            maxIcon.imageScaling = .scaleProportionallyDown
            maxIcon.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 11.0, *) { maxIcon.contentTintColor = PlateColor.textMuted }
            NSLayoutConstraint.activate([
                maxIcon.widthAnchor.constraint(equalToConstant: 12),
                maxIcon.heightAnchor.constraint(equalToConstant: 12),
            ])

            let slider = NSSlider(
                value: Double(libraryViewController?.currentRowHeight ?? 220),
                minValue: Double(LibraryViewController.minRowHeight),
                maxValue: Double(LibraryViewController.maxRowHeight),
                target: self,
                action: #selector(toolbarZoomSlider(_:))
            )
            slider.isContinuous = true
            slider.controlSize = .small
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
            self.zoomSlider = slider

            let stack = NSStackView(views: [minIcon, slider, maxIcon])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = true
            stack.frame = NSRect(x: 0, y: 0, width: 160, height: 24)

            item.view = stack
            item.minSize = NSSize(width: 160, height: 24)
            item.maxSize = NSSize(width: 160, height: 24)
            return item

        default:
            return nil
        }
    }

    @objc private func toolbarZoomSlider(_ sender: NSSlider) {
        libraryViewController?.setRowHeight(CGFloat(sender.doubleValue))
    }

    @objc private func toolbarViewMode(_ sender: NSSegmentedControl) {
        let mode: LibraryViewController.DisplayMode
        switch sender.selectedSegment {
        case 0: mode = .byYear
        case 1: mode = .byMonth
        default: mode = .allPhotos
        }
        libraryViewController?.setDisplayMode(mode)
    }

    @objc private func toolbarSort(_ sender: NSMenuItem) {
        libraryViewController?.setSortOrder(sender.tag == 0 ? .newestFirst : .oldestFirst)
    }

    // MARK: - NSMenuDelegate

    /// Refresh the Sort pull-down's checkmarks to match the library's current
    /// order each time it opens. Tag 0 = newest, 1 = oldest.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sortToolbarMenu else { return }
        let isNewest = (libraryViewController?.sortOrder ?? .newestFirst) == .newestFirst
        for mi in menu.items {
            mi.state = (mi.tag == 0) == isNewest ? .on : .off
        }
    }

    /// Called when the view controller drills down programmatically (clicking
    /// a Year / Month card) so the segmented control reflects the new level.
    private func syncViewModeSegment(_ mode: LibraryViewController.DisplayMode) {
        switch mode {
        case .byYear:    viewModeSegment?.selectedSegment = 0
        case .byMonth:   viewModeSegment?.selectedSegment = 1
        case .allPhotos: viewModeSegment?.selectedSegment = 2
        }
    }

    // MARK: - Import progress

    /// Phase-driven progress reflected in the toolbar spinner + count label.
    /// Replaces the floating HUD pill — Apple Mail / Photos / Notes all keep
    /// in-flight indicators inside the toolbar.
    fileprivate func applyImportPhase(_ phase: LibraryViewController.ImportPhase) {
        switch phase {
        case .scanning:
            setProgressItemVisible(true)
            progressSpinner?.startAnimation(nil)
            progressCountLabel?.isHidden = true
            progressCountLabel?.stringValue = ""
        case .progress(let completed, let total):
            setProgressItemVisible(true)
            progressSpinner?.startAnimation(nil)
            progressCountLabel?.isHidden = total <= 0
            progressCountLabel?.stringValue = total > 0 ? "\(completed) / \(total)" : ""
        case .finished:
            progressSpinner?.stopAnimation(nil)
            progressCountLabel?.isHidden = true
            progressCountLabel?.stringValue = ""
            setProgressItemVisible(false)
        }
    }

    /// Insert the import-progress item just left of the zoom slider while a
    /// scan/import/rebuild runs, and pull it back out when idle. Keeping it out
    /// of the toolbar when there's nothing to report avoids the empty gap Tahoe
    /// would otherwise draw inside the zoom item's grouped background.
    private func setProgressItemVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let existing = toolbar.items.firstIndex { $0.itemIdentifier == TID.progress }
        if visible {
            guard existing == nil else { return }
            let insertAt = toolbar.items.firstIndex { $0.itemIdentifier == TID.zoom }
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: TID.progress, at: insertAt)
        } else if let idx = existing {
            toolbar.removeItem(at: idx)
        }
    }

    private func symbol(_ name: String, fallback: NSImage.Name) -> NSImage? {
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(named: fallback)
        }
        return NSImage(named: fallback)
    }

    // MARK: - Title

    /// NSDocument's automatic title machinery sometimes preserves the `.plate`
    /// extension (e.g. when "Show all filename extensions" is enabled in
    /// Finder). This is the canonical hook to override that mapping.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        if displayName.hasSuffix(".plate") {
            return String(displayName.dropLast(".plate".count))
        }
        return displayName
    }

    /// Called by NSDocument whenever it wants to refresh the window's title.
    /// At that point the framework also reasserts representedURL → the proxy
    /// icon comes back. Re-hide it (and detach representedURL so the system
    /// doesn't try to manage it again).
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        window?.representedURL = nil
        window?.standardWindowButton(.documentIconButton)?.isHidden = true
    }
}
