import AppKit
import PlateCore

final class LibraryViewController: NSViewController,
                                   NSCollectionViewDataSource,
                                   NSCollectionViewDelegate,
                                   NSMenuItemValidation {

    enum ImportPhase {
        case scanning
        case progress(completed: Int, total: Int)
        case finished
    }

    enum DisplayMode {
        case allPhotos
        case byMonth
        case byYear
    }

    /// Capture-date sort direction for the grid, flipped from the View ▸ Sort By
    /// menu. Undated assets always sink to the bottom regardless of direction.
    enum SortOrder {
        case newestFirst
        case oldestFirst
    }

    /// Where the grid pulls its assets from. Driven by the sidebar selection
    /// (Library / Favorites / Recently Deleted / a specific Album). Detail
    /// navigation stays scoped to the current source.
    enum Source: Equatable, Hashable {
        case library
        case favorites
        /// All video assets — a built-in "smart" source backed by a media-type filter.
        case videos
        case recentlyDeleted
        case album(id: UUID, name: String)
    }

    /// One slot in the grid as the data source sees it. In `.allPhotos` mode
    /// every slot is `.asset`. In `.byYear` / `.byMonth` mode each slot is a
    /// `.aggregate` — a single representative asset standing in for a whole
    /// year or month, painted with a big serif label overlay. Clicking an
    /// aggregate jumps to that period inside `.allPhotos`.
    private enum GridSlot {
        case asset(Asset)
        case aggregate(representative: Asset, label: String)

        /// The Asset whose thumbnail this slot displays.
        var representative: Asset {
            switch self {
            case .asset(let a):                return a
            case .aggregate(let rep, _):       return rep
            }
        }
    }

    var library: PlateLibrary?
    /// The currently visible photos, ordered by `sortOrder`. The detail viewer
    /// uses this list for prev/next so it stays inside the current source.
    private(set) var assets: [Asset] = []
    /// Capture-date sort direction. Persists across sidebar source switches;
    /// resets only when the app relaunches (in-memory window state, like zoom).
    private(set) var sortOrder: SortOrder = .newestFirst
    /// Display order — `.asset` slots in `.allPhotos`, `.aggregate` slots in
    /// `.byYear` / `.byMonth`.
    private var gridSlots: [GridSlot] = []
    /// Current display mode (All / Month / Year).
    private(set) var displayMode: DisplayMode = .allPhotos
    /// Current data source — driven by the sidebar.
    private(set) var source: Source = .library
    /// Window controller calls this when an item is opened (double-click / Space).
    var onEnterDetail: ((Int) -> Void)?
    /// Window controller observes this to drive the toolbar progress spinner.
    var onImportPhase: ((ImportPhase) -> Void)?
    /// Notify when the user creates / deletes / renames an album so the
    /// sidebar can refresh its Albums section.
    var onAlbumsChanged: (() -> Void)?
    /// Fires when the display mode changes programmatically (drill-down) so the
    /// segmented control can update its selectedSegment to match.
    var onDisplayModeChanged: ((DisplayMode) -> Void)?
    /// Fires when the smart filter changes so the toolbar can reflect whether a
    /// filter is currently active (e.g. tint / fill the filter button).
    var onFilterChanged: ((SmartFilter) -> Void)?

    private let scrollView = NSScrollView()
    private let collectionView = KeyboardAssetCollectionView()
    private let layout = JustifiedGridLayout()
    private let emptyLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = DropTargetView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        root.wantsLayer = true
        root.layer?.backgroundColor = PlateColor.primary.cgColor
        root.onDrop = { [weak self] urls in self?.importURLs(urls) }
        view = root

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        // Multi-select enabled: click swaps to single, Cmd+click toggles, Shift+
        // click takes a range, and drag-on-empty-area draws a rubber-band.
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(AssetItemView.self,
                                forItemWithIdentifier: AssetItemView.identifier)
        // Space or Return on the selected tile → enter detail (Photos.app convention).
        // On an aggregate (Year / Month card) → jump to that period's photos in
        // All Photos instead of opening the detail viewer.
        collectionView.onActivate = { [weak self] in
            guard let self = self,
                  let idx = self.collectionView.selectionIndexes.first,
                  idx < self.gridSlots.count else { return }
            switch self.gridSlots[idx] {
            case .aggregate:
                self.jumpToAggregate(at: idx)
            case .asset:
                if let flat = self.flatAssetIndex(forGridIndex: idx) {
                    self.onEnterDetail?(flat)
                }
            }
        }
        // Cmd+Delete → trash selected assets.
        collectionView.onDelete = { [weak self] in
            self?.deleteSelectedAssets()
        }
        // Right-click → context menu (Favorite / Add to Album / Trash actions).
        collectionView.onContextMenu = { [weak self] _ in
            self?.buildContextMenu()
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        // Double-click to enter detail view.
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(dbl)

        emptyLabel.alignment = .center
        emptyLabel.textColor = PlateColor.textFaint
        emptyLabel.font = PlateFont.serif(14, italic: true)
        emptyLabel.stringValue = "Drop photos here, or File → Import…"
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(collectionView)
    }

    func reload() {
        guard let lib = library else {
            assets = []
            gridSlots = []
            layout.itemSizes = []
            collectionView.reloadData()
            emptyLabel.isHidden = false
            return
        }
        assets = sortedByCaptureDate(loadAssets(from: lib))
        gridSlots = Self.buildSlots(assets: assets, mode: displayMode)
        layout.itemSizes = gridSlots.map { slot in
            let a = slot.representative
            return CGSize(width: CGFloat(a.pixelWidth ?? 4),
                          height: CGFloat(a.pixelHeight ?? 3))
        }
        collectionView.reloadData()
        emptyLabel.isHidden = !assets.isEmpty
    }

    /// Reload from the DB while keeping the user's scroll position. Used when
    /// returning from the detail viewer after a favorite change: a plain
    /// `reload()` calls `reloadData()`, which snaps the grid back to the top.
    /// Favoriting doesn't change item layout, so the saved offset maps back
    /// exactly; clamping covers the Favorites source, where un-favoriting
    /// removes a tile and shortens the content.
    func reloadPreservingScroll() {
        let clip = scrollView.contentView
        let savedOrigin = clip.bounds.origin
        reload()
        collectionView.layoutSubtreeIfNeeded()
        let maxY = max(0, collectionView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: savedOrigin.x, y: min(savedOrigin.y, maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Switch the asset source (sidebar selection). Resets the display mode
    /// to All Photos so the new source opens in the most direct view.
    func setSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        displayMode = .allPhotos
        onDisplayModeChanged?(displayMode)
        reload()
    }

    /// Refresh assets list from the library according to current `source`.
    /// Each branch hits the matching PlateCore query — soft-deleted rows are
    /// excluded by default in `lib.assets`, so Recently Deleted is the only
    /// view that surfaces them.
    ///
    /// An active smart filter is composed *on top of* the source: we intersect
    /// the source's assets with the filter's matches by id. This keeps the
    /// filter meaningful inside Favorites / a specific Album, not just the whole
    /// Library. Recently Deleted is exempt — the EXIF filter query excludes
    /// trashed rows, so intersecting would always empty it.
    private func loadAssets(from lib: PlateLibrary) -> [Asset] {
        let base: [Asset]
        switch source {
        case .library:         base = lib.assets
        case .favorites:       base = lib.favoriteAssets
        case .videos:          base = lib.assets(matching: SmartFilter(rules: [.mediaType(.video)]))
        case .recentlyDeleted: base = lib.recentlyDeletedAssets
        case .album(let id, _): base = lib.assetsInAlbum(id: id)
        }
        guard !smartFilter.isEmpty, source != .recentlyDeleted else { return base }
        let matchedIDs = Set(lib.assets(matching: smartFilter).map(\.id))
        return base.filter { matchedIDs.contains($0.id) }
    }

    /// Active EXIF smart filter. Empty ⇒ no filtering. Set by the toolbar's
    /// filter popover; applied in `loadAssets(from:)`.
    private(set) var smartFilter = SmartFilter()

    /// Replace the active filter and refresh the grid. Fires `onFilterChanged`
    /// so the toolbar can reflect active/inactive state.
    func setSmartFilter(_ filter: SmartFilter) {
        smartFilter = filter
        onFilterChanged?(filter)
        reload()
    }

    /// Triggered by the toolbar segmented control.
    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        reload()
    }

    /// Triggered by the View ▸ Sort By menu.
    func setSortOrder(_ order: SortOrder) {
        guard sortOrder != order else { return }
        sortOrder = order
        reload()
    }

    /// Order by capture date in the current `sortOrder` direction. Assets with
    /// no `capturedAt` always sort to the bottom in both directions so unknown
    /// dates never jump to the top when the user picks "Oldest First".
    private func sortedByCaptureDate(_ input: [Asset]) -> [Asset] {
        input.sorted { lhs, rhs in
            switch (lhs.capturedAt, rhs.capturedAt) {
            case let (l?, r?): return sortOrder == .newestFirst ? l > r : l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }
    }

    /// View ▸ Sort By ▸ Newest/Oldest First. Tag 0 = newest, 1 = oldest.
    @objc func sortFromMenu(_ sender: NSMenuItem) {
        setSortOrder(sender.tag == 0 ? .newestFirst : .oldestFirst)
    }

    /// Drives the checkmark next to the active Sort By item. Other menu items
    /// resolved to this controller stay enabled (their prior default behavior).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sortFromMenu(_:)):
            let itemIsNewest = (menuItem.tag == 0)
            menuItem.state = (sortOrder == .newestFirst) == itemIsNewest ? .on : .off
            return true
        case #selector(exportMastersFromMenu(_:)):
            // File ▸ Export Photos… — needs at least one selected photo.
            return !currentSelectedAssets().isEmpty
        case #selector(exportOriginalsFromMenu(_:)):
            // File ▸ Export Originals (with RAW)… — only when the selection
            // actually carries a RAW or sidecar to bring along.
            return currentSelectedAssets().contains { !$0.raws.isEmpty || !$0.sidecars.isEmpty }
        case #selector(toggleFavorite(_:)):
            // Image ▸ Favorite / ".". Enabled only with a grid selection; the
            // title shows "Unfavorite" when everything selected is already a
            // favorite. While a text field edits it owns the responder chain, so
            // return false to let "." type instead of toggling.
            if view.window?.firstResponder is NSText { return false }
            let sel = currentSelectedAssets()
            menuItem.title = (!sel.isEmpty && sel.allSatisfy { $0.isFavorite }) ? "Unfavorite" : "Favorite"
            return !sel.isEmpty
        case Selector(("undo:")):
            // Mirror the manager's state into the Edit ▸ Undo item ("Undo
            // Favorite", etc.). When a text field is editing, its field editor
            // sits earlier in the responder chain and handles undo: instead.
            let mgr = libraryUndoManager
            menuItem.title = mgr?.undoMenuItemTitle ?? "Undo"
            return mgr?.canUndo ?? false
        case Selector(("redo:")):
            let mgr = libraryUndoManager
            menuItem.title = mgr?.redoMenuItemTitle ?? "Redo"
            return mgr?.canRedo ?? false
        default:
            return true
        }
    }

    /// Edit ▸ Undo / ⌘Z. Explicit handler keeps undo deterministic regardless
    /// of AppKit's implicit window-undo plumbing; the VC is in the responder
    /// chain after the grid, so it catches undo: whenever no text editor does.
    @objc func undo(_ sender: Any?) { libraryUndoManager?.undo() }
    /// Edit ▸ Redo / ⇧⌘Z.
    @objc func redo(_ sender: Any?) { libraryUndoManager?.redo() }

    /// Open the period represented by an aggregate card by switching to All
    /// Photos and scrolling to the first asset in that year (and month, if the
    /// click originated from a Month card). No drill stack, no back button —
    /// the segmented control is the only nav affordance.
    private func jumpToAggregate(at slotIndex: Int) {
        guard slotIndex >= 0, slotIndex < gridSlots.count,
              case .aggregate(let rep, _) = gridSlots[slotIndex],
              let date = rep.capturedAt else { return }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: date)
        let targetYear = comps.year
        // From a Year card, jump to "first photo of that year"; from a Month
        // card, narrow further to "first photo of that month". `.allPhotos`
        // aggregates don't exist, so the else-branch is dead but harmless.
        let targetMonth: Int? = (displayMode == .byMonth) ? comps.month : nil

        // Switch to flat All Photos. The segmented control follows via the
        // onDisplayModeChanged hook.
        let needsModeSwitch = displayMode != .allPhotos
        displayMode = .allPhotos
        if needsModeSwitch {
            onDisplayModeChanged?(displayMode)
            reload()
        }

        // Locate the first matching asset in the freshly-built flat list.
        guard let targetIndex = assets.firstIndex(where: { asset in
            guard let d = asset.capturedAt else { return false }
            let c = cal.dateComponents([.year, .month], from: d)
            guard c.year == targetYear else { return false }
            if let m = targetMonth { return c.month == m }
            return true
        }) else { return }

        // Layout has to finish before scrollToItems knows where to land.
        // Defer one runloop turn after the reload.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let path: Set<IndexPath> = [IndexPath(item: targetIndex, section: 0)]
            self.collectionView.scrollToItems(at: path, scrollPosition: [.top])
            // Briefly select it so the user can see where they landed.
            self.collectionView.deselectAll(nil)
            self.collectionView.selectItems(at: path, scrollPosition: [])
        }
    }

    // MARK: - Grouping into sections

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// `.allPhotos` → one slot per photo.
    /// `.byMonth` / `.byYear` → one aggregate slot per period, using the most
    /// recent asset in that period as the visual representative.
    private static func buildSlots(assets: [Asset], mode: DisplayMode) -> [GridSlot] {
        switch mode {
        case .allPhotos:
            return assets.map { .asset($0) }

        case .byMonth:
            return aggregate(assets: assets, key: { date in
                let comps = Calendar(identifier: .gregorian)
                    .dateComponents([.year, .month], from: date)
                return "\(comps.year ?? 0)-\(comps.month ?? 0)"
            }, title: { date in monthFormatter.string(from: date) })

        case .byYear:
            return aggregate(assets: assets, key: { date in
                String(Calendar(identifier: .gregorian).component(.year, from: date))
            }, title: { date in yearFormatter.string(from: date) })
        }
    }

    /// Walk `assets` (already sorted by the current `sortOrder`), group by
    /// `key(date)`, and emit one `.aggregate` per group with the first asset
    /// encountered in that bucket as the representative.
    private static func aggregate(assets: [Asset],
                                  key: (Date) -> String,
                                  title: (Date) -> String) -> [GridSlot]
    {
        var slots: [GridSlot] = []
        var currentKey: String?
        for asset in assets {
            let bucketKey: String
            let bucketTitle: String
            if let date = asset.capturedAt {
                bucketKey = key(date)
                bucketTitle = title(date)
            } else {
                bucketKey = "_undated"
                bucketTitle = "Undated"
            }
            if currentKey != bucketKey {
                // First asset for this period — make it the representative.
                slots.append(.aggregate(representative: asset, label: bucketTitle))
                currentKey = bucketKey
            }
            // Subsequent assets in the same period are folded into the aggregate
            // (no slot is emitted for them in aggregated modes).
        }
        return slots
    }

    var currentRowHeight: CGFloat {
        layout.targetRowHeight
    }

    func adjustRowHeight(by delta: CGFloat) {
        setRowHeight(layout.targetRowHeight + delta)
    }

    func setRowHeight(_ value: CGFloat) {
        layout.targetRowHeight = max(Self.minRowHeight, min(Self.maxRowHeight, value))
    }

    /// Slider + menu-shortcut bounds for thumbnail row height. Min low enough
    /// for a "contact sheet" overview, max high enough for one photo per row.
    static let minRowHeight: CGFloat = 60
    static let maxRowHeight: CGFloat = 700

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu? {
        let selectedAssets = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        guard !selectedAssets.isEmpty, let lib = library else { return nil }
        let menu = NSMenu()

        // Open
        let open = NSMenuItem(title: "Open", action: #selector(openSelectedFromMenu(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // Favorite toggle — bulk on the whole selection.
        let allFav = selectedAssets.allSatisfy { $0.isFavorite }
        let favTitle = allFav
            ? "Remove from Favorites"
            : (selectedAssets.count == 1 ? "Favorite" : "Favorite \(selectedAssets.count) Photos")
        let favItem = NSMenuItem(title: favTitle,
                                 action: #selector(toggleFavoriteFromMenu(_:)),
                                 keyEquivalent: "")
        favItem.target = self
        if #available(macOS 11.0, *) {
            favItem.image = NSImage(systemSymbolName: allFav ? "heart.fill" : "heart",
                                    accessibilityDescription: nil)
        }
        menu.addItem(favItem)

        // Add to Album → submenu of existing albums + "New Album…".
        let albumsMenu = NSMenu(title: "Add to Album")
        for album in lib.albums {
            let m = NSMenuItem(title: album.name,
                               action: #selector(addToAlbumFromMenu(_:)),
                               keyEquivalent: "")
            m.target = self
            m.representedObject = album.id
            albumsMenu.addItem(m)
        }
        if !lib.albums.isEmpty { albumsMenu.addItem(.separator()) }
        let newAlbum = NSMenuItem(title: "New Album…",
                                  action: #selector(newAlbumFromMenu(_:)),
                                  keyEquivalent: "")
        newAlbum.target = self
        albumsMenu.addItem(newAlbum)

        let addToItem = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        addToItem.submenu = albumsMenu
        menu.addItem(addToItem)

        // Export — copy the originals out of the library to a chosen folder.
        menu.addItem(.separator())
        let n = selectedAssets.count
        let exportItem = NSMenuItem(title: n == 1 ? "Export Photo…" : "Export \(n) Photos…",
                                    action: #selector(exportMastersFromMenu(_:)),
                                    keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)
        // Only offer "with RAW" when there's actually a RAW/sidecar to bring along.
        if selectedAssets.contains(where: { !$0.raws.isEmpty || !$0.sidecars.isEmpty }) {
            let origItem = NSMenuItem(title: n == 1 ? "Export Original (with RAW)…"
                                                    : "Export \(n) Originals (with RAW)…",
                                      action: #selector(exportOriginalsFromMenu(_:)),
                                      keyEquivalent: "")
            origItem.target = self
            menu.addItem(origItem)
        }

        // Source-specific destructive actions.
        menu.addItem(.separator())
        switch source {
        case .recentlyDeleted:
            let restore = NSMenuItem(title: "Restore",
                                     action: #selector(restoreFromMenu(_:)),
                                     keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
            let perm = NSMenuItem(title: "Delete Permanently…",
                                  action: #selector(permanentlyDeleteFromMenu(_:)),
                                  keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        case .album(let id, _):
            let remove = NSMenuItem(title: "Remove from Album",
                                    action: #selector(removeFromAlbumFromMenu(_:)),
                                    keyEquivalent: "")
            remove.target = self
            remove.representedObject = id
            menu.addItem(remove)
            menu.addItem(.separator())
            let trash = NSMenuItem(title: "Move to Trash",
                                   action: #selector(moveToTrashFromMenu(_:)),
                                   keyEquivalent: "")
            trash.target = self
            menu.addItem(trash)
        default:
            let trash = NSMenuItem(title: "Move to Trash",
                                   action: #selector(moveToTrashFromMenu(_:)),
                                   keyEquivalent: "")
            trash.target = self
            menu.addItem(trash)
        }

        return menu
    }

    @objc private func openSelectedFromMenu(_ sender: Any?) {
        guard let idx = collectionView.selectionIndexes.first,
              let flat = flatAssetIndex(forGridIndex: idx) else { return }
        onEnterDetail?(flat)
    }

    // MARK: - Undo-able edits

    /// The window's undo manager (vended by LibraryWindowController). Reversible
    /// library edits register their inverse here so Edit ▸ Undo / Redo
    /// (⌘Z / ⇧⌘Z) can roll them back.
    private var libraryUndoManager: UndoManager? { view.window?.undoManager }

    /// Apply per-asset favorite states and register the inverse. `newStates` and
    /// `oldStates` run parallel to `assets`; undo re-invokes with them swapped,
    /// so redo registers itself through the same code path. The handler captures
    /// only value types + the target param — no retain cycle with self.
    private func applyFavorite(assets: [Asset], newStates: [Bool], oldStates: [Bool], actionName: String) {
        guard let lib = library,
              assets.count == newStates.count, assets.count == oldStates.count else { return }
        do {
            for (asset, state) in zip(assets, newStates) {
                try lib.setFavorite(asset, isFavorite: state)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        libraryUndoManager?.registerUndo(withTarget: self) { vc in
            vc.applyFavorite(assets: assets, newStates: oldStates, oldStates: newStates, actionName: actionName)
        }
        libraryUndoManager?.setActionName(actionName)
        reload()
    }

    /// Favorite/unfavorite a single asset through the standard grid path — DB
    /// write, undo registration, reload — exposed so the window controller can
    /// replay a detail-viewer favorite for ⌘Z. The caller's undo handler
    /// captures `asset` by value, so it still resolves even if the grid later
    /// drops the row (e.g. un-favoriting inside the Favorites source).
    /// `oldStates` is `!isFavorite`: favoriting is a boolean toggle, so the
    /// previous value is always the inverse.
    func favoriteAsset(_ asset: Asset, isFavorite: Bool, actionName: String) {
        applyFavorite(assets: [asset], newStates: [isFavorite],
                      oldStates: [!isFavorite], actionName: actionName)
    }

    /// Add or remove album membership and register the inverse (add ⇄ remove).
    private func applyAlbumMembership(assets: [Asset], albumID: UUID, add: Bool, actionName: String) {
        guard let lib = library, !assets.isEmpty else { return }
        do {
            if add { try lib.addAssets(assets, toAlbum: albumID) }
            else   { try lib.removeAssets(assets, fromAlbum: albumID) }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        libraryUndoManager?.registerUndo(withTarget: self) { vc in
            vc.applyAlbumMembership(assets: assets, albumID: albumID, add: !add, actionName: actionName)
        }
        libraryUndoManager?.setActionName(actionName)
        onAlbumsChanged?()
        reload()
    }

    /// Soft-delete (trash) or restore and register the inverse (trash ⇄ restore).
    /// Both directions are quick DB updates, so they run synchronously on the
    /// main thread — undo handlers must touch the UI on main anyway.
    private func applyTrash(assets: [Asset], trash: Bool, actionName: String) {
        guard let lib = library, !assets.isEmpty else { return }
        do {
            if trash { try lib.deleteAssets(assets) }
            else     { try lib.restoreAssets(assets) }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        libraryUndoManager?.registerUndo(withTarget: self) { vc in
            vc.applyTrash(assets: assets, trash: !trash, actionName: actionName)
        }
        libraryUndoManager?.setActionName(actionName)
        reload()
    }

    @objc private func toggleFavoriteFromMenu(_ sender: Any?) {
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        guard !selected.isEmpty else { return }
        let allFav = selected.allSatisfy { $0.isFavorite }
        let target = !allFav
        applyFavorite(assets: selected,
                      newStates: selected.map { _ in target },
                      oldStates: selected.map { $0.isFavorite },
                      actionName: target ? "Favorite" : "Remove from Favorites")
    }

    /// Image ▸ Favorite / "." for the grid. Shares the menu command selector
    /// with the detail viewer (the responder chain routes it to whichever is
    /// active); same behavior as the right-click Favorite entry point.
    @objc func toggleFavorite(_ sender: Any?) { toggleFavoriteFromMenu(sender) }

    @objc private func addToAlbumFromMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let albumID = menuItem.representedObject as? UUID else { return }
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        applyAlbumMembership(assets: selected, albumID: albumID, add: true, actionName: "Add to Album")
    }

    @objc private func removeFromAlbumFromMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let albumID = menuItem.representedObject as? UUID else { return }
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        applyAlbumMembership(assets: selected, albumID: albumID, add: false, actionName: "Remove from Album")
    }

    @objc func newAlbumFromMenu(_ sender: Any?) {
        guard let lib = library, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "New Album"
        alert.informativeText = "Choose a name for the new album."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Untitled Album"
        alert.accessoryView = field

        // Pre-collect any current selection so we can drop it into the new
        // album when called from the context menu / drag flow.
        let selectedAssetsAtTime = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = name.isEmpty ? "Untitled Album" : name
            do {
                let albumID = try lib.createAlbum(name: finalName)
                if !selectedAssetsAtTime.isEmpty {
                    try lib.addAssets(selectedAssetsAtTime, toAlbum: albumID)
                }
                self?.onAlbumsChanged?()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func moveToTrashFromMenu(_ sender: Any?) {
        deleteSelectedAssets()
    }

    @objc func exportMastersFromMenu(_ sender: Any?) {
        exportSelected(includeRaws: false, includeSidecars: false)
    }

    @objc func exportOriginalsFromMenu(_ sender: Any?) {
        exportSelected(includeRaws: true, includeSidecars: true)
    }

    /// Assets backing the current grid selection (aggregate cards excluded).
    /// Shared by the export actions and their menu-bar validation.
    private func currentSelectedAssets() -> [Asset] {
        deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
    }

    /// Ask for a destination folder, then copy the selected assets' files there
    /// off the main thread. Masters always; RAW + sidecars when requested.
    private func exportSelected(includeRaws: Bool, includeSidecars: Bool) {
        guard let lib = library, let window = view.window else { return }
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        guard !selected.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for \(selected.count) photo\(selected.count == 1 ? "" : "s")."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dest = panel.url, let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? lib.exportAssets(selected, to: dest,
                                                   includeRaws: includeRaws,
                                                   includeSidecars: includeSidecars)
                DispatchQueue.main.async {
                    self.presentExportSummary(result, destination: dest, requested: selected.count)
                }
            }
        }
    }

    private func presentExportSummary(_ result: PlateLibrary.ExportResult?,
                                      destination: URL,
                                      requested: Int) {
        let exported = result?.exported ?? 0
        let failed = result?.failures.count ?? requested
        let alert = NSAlert()
        if failed == 0 {
            alert.alertStyle = .informational
            alert.messageText = "Exported \(exported) photo\(exported == 1 ? "" : "s")"
            alert.informativeText = destination.path
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "Done")
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Exported \(exported), \(failed) failed"
            alert.informativeText = (result?.failures.prefix(5).map {
                "  • " + ($0.asset.primary as NSString).lastPathComponent
            }.joined(separator: "\n")) ?? "The destination may not be writable."
            alert.addButton(withTitle: "OK")
        }
        let reveal: (NSApplication.ModalResponse) -> Void = { response in
            if failed == 0, response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: reveal)
        } else {
            reveal(alert.runModal())
        }
    }

    @objc private func restoreFromMenu(_ sender: Any?) {
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        applyTrash(assets: selected, trash: false, actionName: "Restore")
    }

    @objc private func permanentlyDeleteFromMenu(_ sender: Any?) {
        guard let lib = library else { return }
        let selected = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }.sorted())
        guard !selected.isEmpty else { return }
        let count = selected.count
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(count) photo\(count == 1 ? "" : "s") permanently?"
        alert.informativeText = "Originals, RAW companions, sidecars and thumbnails will be removed from disk. This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try lib.permanentlyDeleteAssets(selected)
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
                DispatchQueue.main.async { self?.reload() }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func deleteSelectedAssets() {
        // In Recently Deleted, Cmd+Delete escalates to permanent deletion
        // since the asset is already in the trash.
        if source == .recentlyDeleted {
            permanentlyDeleteFromMenu(nil)
            return
        }
        guard library != nil else { return }
        let toDelete = deletableAssets(forGridIndices: collectionView.selectionIndexPaths
            .map { $0.item }
            .sorted())
        guard !toDelete.isEmpty else { return }
        let count = toDelete.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(count) photo\(count == 1 ? "" : "s") to Trash?"
        alert.informativeText = "They'll go to Recently Deleted. You can put them back with Undo (⌘Z) or from Recently Deleted."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.applyTrash(assets: toDelete, trash: true, actionName: "Move to Trash")
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func presentImportSummary(_ result: PlateLibrary.ImportResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        let imported = result.imported.count
        let dups     = result.duplicates.count
        let fails    = result.failures.count

        var headline: [String] = []
        if imported > 0 { headline.append("Imported \(imported)") }
        if dups > 0     { headline.append("\(dups) already in library") }
        if fails > 0    { headline.append("\(fails) couldn't be read") }
        alert.messageText = headline.joined(separator: ", ")

        var body = ""
        if dups > 0 {
            body += "Skipped (already in library):\n"
            body += result.duplicates.prefix(5)
                .map { "  • " + $0.source.lastPathComponent }
                .joined(separator: "\n")
            if dups > 5 { body += "\n  … and \(dups - 5) more." }
        }
        if fails > 0 {
            if !body.isEmpty { body += "\n\n" }
            body += "Couldn't be imported:\n"
            body += result.failures.prefix(5)
                .map { "  • " + $0.source.lastPathComponent }
                .joined(separator: "\n")
            if fails > 5 { body += "\n  … and \(fails - 5) more." }
        }
        alert.informativeText = body

        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func importURLs(_ urls: [URL]) {
        guard let lib = library, !urls.isEmpty else { return }
        // Dropping onto an album view files the imports straight into that album.
        // Captured now (drop time) so switching the sidebar mid-import can't
        // retarget where they land.
        let targetAlbumID: UUID? = {
            if case .album(let id, _) = source { return id }
            return nil
        }()
        // Skip anything that IS or IS INSIDE this library bundle. Without the
        // equality check, dragging the document proxy icon (or the bundle
        // itself from Finder) onto our own window would re-import every
        // photo as a fresh duplicate.
        let libPath = lib.url.standardizedFileURL.path
        let libPathPrefix = libPath + "/"
        let isInsideLibrary: (URL) -> Bool = { url in
            let p = url.standardizedFileURL.path
            return p == libPath || p.hasPrefix(libPathPrefix)
        }
        let externalURLs = urls.filter { !isInsideLibrary($0) }
        guard !externalURLs.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onImportPhase?(.scanning)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var files: [URL] = []
                for u in externalURLs {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir),
                       isDir.boolValue {
                        files += try LibraryScanner.scan(directory: u)
                    } else {
                        files.append(u)
                    }
                }
                // After scanning, also filter directory-scanned files in case a
                // user drops a parent folder that contains the library itself.
                let externalFiles = files.filter { !isInsideLibrary($0) }
                let pairs = AssetPairer.pair(files: externalFiles)
                let result = try lib.importPairs(pairs) { [weak self] completed, total in
                    DispatchQueue.main.async {
                        self?.onImportPhase?(.progress(completed: completed, total: total))
                    }
                }
                // File the drop into the album it landed on. Both the freshly
                // imported assets and any that were already in the library
                // (deduped) join the album — dropping a photo onto an album
                // should put it there regardless of whether it's new.
                if let albumID = targetAlbumID {
                    let toAdd = result.imported + result.duplicates.map(\.existing)
                    if !toAdd.isEmpty { try lib.addAssets(toAdd, toAlbum: albumID) }
                }
                if !result.failures.isEmpty || !result.duplicates.isEmpty {
                    let snapshot = result
                    DispatchQueue.main.async {
                        self?.presentImportSummary(snapshot)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let window = self?.view.window {
                        NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        NSAlert(error: error).runModal()
                    }
                }
            }
            DispatchQueue.main.async {
                self?.onImportPhase?(.finished)
                self?.reload()
            }
        }
    }

    // MARK: - Slot <-> asset index helpers

    /// For a tile at a given grid index, return the flat `assets[i]` index of
    /// its representative — used to enter the Detail viewer at the right point
    /// in the navigation sequence.
    private func flatAssetIndex(forGridIndex idx: Int) -> Int? {
        guard idx >= 0, idx < gridSlots.count else { return nil }
        let rep = gridSlots[idx].representative
        return assets.firstIndex(where: { $0.id == rep.id })
    }

    /// For Cmd+Delete: only individual photos are deletable. Aggregate slots
    /// (Year / Month cards) are skipped to avoid surprising "delete the whole
    /// year" outcomes — switch to All Photos to delete in those modes.
    private func deletableAssets(forGridIndices indices: [Int]) -> [Asset] {
        indices.compactMap { idx -> Asset? in
            guard idx < gridSlots.count, case .asset(let a) = gridSlots[idx] else { return nil }
            return a
        }
    }

    // MARK: - Detail entry

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let path = collectionView.indexPathForItem(at: point),
              path.item < gridSlots.count else { return }
        switch gridSlots[path.item] {
        case .aggregate:
            jumpToAggregate(at: path.item)
        case .asset:
            if let flat = flatAssetIndex(forGridIndex: path.item) {
                onEnterDetail?(flat)
            }
        }
    }


    // MARK: - NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        gridSlots.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: AssetItemView.identifier,
                               for: indexPath) as! AssetItemView
        let slot = gridSlots[indexPath.item]
        let asset = slot.representative
        let thumbURL = asset.thumbnail.flatMap { library?.absoluteURL(forRelative: $0) }
        switch slot {
        case .asset:
            item.configure(thumbnailURL: thumbURL,
                           formatBadge: Self.formatBadge(for: asset),
                           bigOverlay: nil,
                           isFavorite: asset.isFavorite,
                           mediaType: asset.mediaType,
                           duration: asset.duration)
            // Capture by asset.id rather than by `asset` (a struct) so the
            // closure stays correct even after the user reorders / filters.
            let assetID = asset.id
            item.onToggleFavorite = { [weak self] in
                self?.toggleFavoriteByID(assetID)
            }
        case .aggregate(_, let label):
            // Aggregate tile (Year / Month card) — no format badge, big serif
            // period label centred on the representative photo. Don't echo
            // the representative's favorite state — would mislead the user
            // into thinking the whole year/month is favorited.
            item.configure(thumbnailURL: thumbURL,
                           formatBadge: nil,
                           bigOverlay: label,
                           isFavorite: false)
            item.onToggleFavorite = nil
        }
        return item
    }

    /// Per-tile heart click handler. Looks up the asset by id (the closure
    /// captures id, not the asset value, so it's still valid after a reload).
    private func toggleFavoriteByID(_ id: UUID) {
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        let target = !asset.isFavorite
        applyFavorite(assets: [asset],
                      newStates: [target],
                      oldStates: [asset.isFavorite],
                      actionName: target ? "Favorite" : "Remove from Favorites")
    }

    /// "JPEG", "HEIF", "HEIF + RAW", "JPEG + RAW", "RAW" — what the corner
    /// badge displays. Computed from the primary file's extension plus whether
    /// any RAW companions are paired alongside. Delegates to PlateCore's
    /// `Asset.formatLabel` so the badge and the Statistics "by format"
    /// breakdown share one definition of the folded format string.
    private static func formatBadge(for asset: Asset) -> String {
        asset.formatLabel
    }
}

/// NSCollectionView swallows Space and Return by default. Subclass so we can
/// route them to "open the selected tile" — matching Photos.app's convention.
/// Arrow keys still go to the standard navigation path via `super`.
/// Also routes Cmd+Delete → onDelete for batch removal, implements proper
/// Shift+click range selection (the default NSCollectionView behavior is
/// inconsistent across layouts), and surfaces a right-click context menu.
private final class KeyboardAssetCollectionView: NSCollectionView {
    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Build a context menu for the right-clicked item (already selected by
    /// the time this fires). Return nil to suppress.
    var onContextMenu: ((IndexPath) -> NSMenu?)?

    /// The "anchor" — last non-Shift click. Shift+click selects every item
    /// between the anchor and the new click, inclusive.
    private var anchorIndex: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        // Ensure the right-clicked item is selected (Photos.app behavior).
        if !selectionIndexPaths.contains(path) {
            deselectItems(at: selectionIndexPaths)
            selectItems(at: [path], scrollPosition: [])
            anchorIndex = path.item
        }
        return onContextMenu?(path)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let clicked = indexPathForItem(at: point) else {
            super.mouseDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift) {
            let target = clicked.item
            let anchor = anchorIndex ?? target
            let lo = min(anchor, target)
            let hi = max(anchor, target)
            let range = Set((lo...hi).map { IndexPath(item: $0, section: 0) })
            deselectItems(at: selectionIndexPaths)
            selectItems(at: range, scrollPosition: [])
            // Anchor stays put on Shift+click — repeated Shift+clicks extend the
            // same range, just like Finder / Apple Photos.
            return
        }

        super.mouseDown(with: event)

        // Update anchor on plain click or Cmd+click — that's the new pivot.
        anchorIndex = clicked.item
    }

    override func keyDown(with event: NSEvent) {
        // 49 = Space, 36 = Return → open detail
        if event.keyCode == 49 || event.keyCode == 36 {
            onActivate?()
            return
        }
        // 51 = Delete/Backspace, with ⌘ → trash selection
        if event.keyCode == 51, event.modifierFlags.contains(.command) {
            onDelete?()
            return
        }
        // 53 = Escape → clear the current selection. Only consumed when
        // something is selected, so an empty-selection Esc still falls through
        // to its default (e.g. exit full screen).
        if event.keyCode == 53, !selectionIndexPaths.isEmpty {
            deselectItems(at: selectionIndexPaths)
            anchorIndex = nil
            return
        }
        super.keyDown(with: event)
    }
}

/// Whole-view drop target — accepts file URLs and forwards them via the closure.
private final class DropTargetView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
