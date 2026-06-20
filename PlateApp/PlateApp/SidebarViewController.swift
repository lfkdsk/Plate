import AppKit
import PlateCore

/// Photos-app-style source list on the left of the window: a tree of sidebar
/// items grouped under headers ("Photos", "Albums") that selects which set of
/// assets the main grid is showing.
///
/// Pre-defined items (Library / Favorites / Recently Deleted) live under
/// "Photos". The "Albums" section is populated dynamically from
/// `PlateLibrary.albums` once that API lands on the library side; until then
/// the section renders empty.
final class SidebarViewController: NSViewController {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    /// Owning library. Reassigned via the window controller; triggers a refresh
    /// of the Albums section.
    var library: PlateLibrary? {
        didSet { refreshAlbums() }
    }

    /// Fired when the user clicks a selectable sidebar item (not a header).
    var onSelectSource: ((LibraryViewController.Source) -> Void)?
    /// Fired when the user clicks the "+" button on the ALBUMS section header.
    /// Window controller pipes this through to LibraryViewController's
    /// `newAlbumFromMenu(_:)` flow so we share one "New Album" dialog.
    var onNewAlbumRequested: (() -> Void)?

    private let photosHeader = SidebarItem(title: "Photos", children: [
        SidebarItem(title: "Library",           icon: "photo.on.rectangle.angled", source: .library),
        SidebarItem(title: "Favorites",         icon: "heart",                     source: .favorites),
        SidebarItem(title: "Videos",            icon: "video",                     source: .videos),
        SidebarItem(title: "Recently Deleted",  icon: "trash",                     source: .recentlyDeleted),
    ])
    private let albumsHeader = SidebarItem(title: "Albums", children: [])

    private var rootItems: [SidebarItem] { [photosHeader, albumsHeader] }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        view = root

        outlineView.headerView = nil
        outlineView.indentationPerLevel = 8
        outlineView.rowHeight = 26
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.gridStyleMask = []
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            outlineView.style = .sourceList
        }
        // Drag-to-reorder, scoped to the Albums section (see the DnD data-source
        // methods below — only album rows are draggable / droppable).
        outlineView.registerForDraggedTypes([.plateAlbumRow])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.isEditable = false
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        outlineView.expandItem(photosHeader, expandChildren: true)
        outlineView.expandItem(albumsHeader)
        // Default selection → Library (row index of the first child of photosHeader).
        if let firstItem = photosHeader.children.first {
            let row = outlineView.row(forItem: firstItem)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    /// Re-fetch the user's albums and rebuild the Albums section. Called from
    /// `library` didSet and after album CRUD operations.
    func refreshAlbums() {
        guard let lib = library else {
            albumsHeader.children = []
            outlineView.reloadItem(albumsHeader, reloadChildren: true)
            return
        }
        albumsHeader.children = lib.albums.map { entry in
            SidebarItem(
                title: entry.name,
                icon: "rectangle.stack",
                source: .album(id: entry.id, name: entry.name)
            )
        }
        outlineView.reloadItem(albumsHeader, reloadChildren: true)
        outlineView.expandItem(albumsHeader)
    }
}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems.count }
        return (item as? SidebarItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootItems[index] }
        return (item as! SidebarItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.children.isEmpty == false
    }

    // MARK: Drag-to-reorder (Albums only)

    /// Only album rows are draggable. The pasteboard carries the row's index
    /// within `albumsHeader.children`.
    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem,
              let index = albumsHeader.children.firstIndex(where: { $0 === sidebarItem })
        else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(index), forType: .plateAlbumRow)
        return pb
    }

    /// Accept drops only inside the Albums group. Drops landing on a row or on
    /// the header are retargeted to a between-rows insertion so AppKit shows the
    /// drop line in the right place.
    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingPasteboard.availableType(from: [.plateAlbumRow]) != nil else { return [] }
        if (item as? SidebarItem) === albumsHeader {
            if index == -1 {
                outlineView.setDropItem(albumsHeader, dropChildIndex: albumsHeader.children.count)
            }
            return .move
        }
        // Dropped directly on an album row → insert before that row.
        if let target = item as? SidebarItem,
           let row = albumsHeader.children.firstIndex(where: { $0 === target }) {
            outlineView.setDropItem(albumsHeader, dropChildIndex: row)
            return .move
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: .plateAlbumRow),
              let sourceIndex = Int(str),
              sourceIndex >= 0, sourceIndex < albumsHeader.children.count
        else { return false }

        // CRITICAL: do NOT mutate the model / reloadItem synchronously here.
        // Reloading inside performDragOperation frees the row views + items that
        // AppKit is still messaging as it tears the drag down → EXC_BAD_ACCESS in
        // -[NSOutlineView performDragOperation:]. Return true to let the drag
        // finish, then reorder on the next runloop tick.
        let proposedIndex = index
        DispatchQueue.main.async { [weak self] in
            self?.commitAlbumReorder(sourceIndex: sourceIndex, proposedIndex: proposedIndex)
        }
        return true
    }

    /// Apply a reorder after the drop has fully settled (see `acceptDrop`).
    private func commitAlbumReorder(sourceIndex: Int, proposedIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < albumsHeader.children.count else { return }

        // Preserve the current sidebar selection across the reload so a reorder
        // doesn't yank the grid to a different source.
        let selected = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem

        var children = albumsHeader.children
        let moved = children.remove(at: sourceIndex)
        var dest = (proposedIndex == -1) ? children.count : proposedIndex
        if sourceIndex < dest { dest -= 1 }          // account for the removal
        dest = max(0, min(dest, children.count))
        children.insert(moved, at: dest)
        albumsHeader.children = children

        if let lib = library {
            let ids = children.compactMap { albumID(of: $0) }
            do { try lib.reorderAlbums(orderedIDs: ids) }
            catch { NSAlert(error: error).runModal() }
        }

        outlineView.reloadItem(albumsHeader, reloadChildren: true)
        outlineView.expandItem(albumsHeader)
        if let selected = selected {
            let row = outlineView.row(forItem: selected)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func albumID(of item: SidebarItem) -> UUID? {
        if case .album(let id, _)? = item.source { return id }
        return nil
    }
}

extension NSPasteboard.PasteboardType {
    static let plateAlbumRow = NSPasteboard.PasteboardType("com.lfkdsk.plate.album-row")
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: sidebarItem.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false

        if sidebarItem.isHeader {
            // Section header — uppercased, mono-ish small caps for editorial feel.
            let attr = NSMutableAttributedString(string: sidebarItem.title.uppercased())
            attr.addAttributes([
                .font: PlateFont.mono(10, weight: .semibold),
                .foregroundColor: PlateColor.textSubtle,
                .kern: 1.2,
            ], range: NSRange(location: 0, length: attr.length))
            label.attributedStringValue = attr
            cell.addSubview(label)
            cell.textField = label

            // ALBUMS header gets a trailing "+" button — one-click "New Album"
            // from the same row, no dive into File menu or right-click required.
            // PHOTOS header stays plain (its items are fixed).
            if sidebarItem === albumsHeader {
                let plus = NSButton()
                plus.isBordered = false
                plus.bezelStyle = .smallSquare
                plus.title = ""
                plus.imageScaling = .scaleProportionallyDown
                plus.target = self
                plus.action = #selector(handleNewAlbumClick(_:))
                plus.toolTip = "New Album"
                if #available(macOS 11.0, *) {
                    let conf = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    plus.image = NSImage(systemSymbolName: "plus",
                                         accessibilityDescription: "New Album")?
                        .withSymbolConfiguration(conf)
                    plus.contentTintColor = PlateColor.textSubtle
                }
                plus.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(plus)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    plus.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
                    plus.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    plus.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    plus.widthAnchor.constraint(equalToConstant: 18),
                    plus.heightAnchor.constraint(equalToConstant: 18),
                ])
            } else {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                ])
            }
        } else {
            // Selectable item — SF Symbol icon + body label.
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 11.0, *) {
                let conf = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                iconView.image = NSImage(systemSymbolName: sidebarItem.icon,
                                         accessibilityDescription: nil)?
                    .withSymbolConfiguration(conf)
                iconView.contentTintColor = PlateColor.accent
            }
            iconView.imageScaling = .scaleProportionallyDown

            label.font = PlateFont.body(13)
            label.textColor = PlateColor.textPrimary

            cell.imageView = iconView
            cell.textField = label
            cell.addSubview(iconView)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),

                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            ])
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem,
              let source = item.source else { return }
        onSelectSource?(source)
    }

    @objc fileprivate func handleNewAlbumClick(_ sender: Any?) {
        onNewAlbumRequested?()
    }
}

// MARK: - Item

/// Class-backed node — NSOutlineView relies on object identity for items and
/// the row<->item lookups, so we can't use a value type here.
final class SidebarItem {
    let title: String
    let icon: String
    let source: LibraryViewController.Source?
    var children: [SidebarItem]

    var isHeader: Bool { source == nil }

    init(title: String,
         icon: String = "",
         source: LibraryViewController.Source? = nil,
         children: [SidebarItem] = [])
    {
        self.title = title
        self.icon = icon
        self.source = source
        self.children = children
    }
}
