import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(shareMenu())
        main.addItem(windowMenu())
        return main
    }

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(.init(title: "About Plate",
                           action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                           keyEquivalent: ""))
        menu.addItem(.separator())
        // In-app update check — queries GitHub Releases and offers to open the
        // download page when a newer version is published. Routed to the app
        // delegate through the responder chain.
        menu.addItem(.init(title: "Check for Updates…",
                           action: #selector(AppDelegate.checkForUpdatesFromMenu(_:)),
                           keyEquivalent: ""))
        menu.addItem(.separator())
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(.init(title: "Hide Plate",
                           action: #selector(NSApplication.hide(_:)),
                           keyEquivalent: "h"))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit Plate",
                           action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q"))
        item.submenu = menu
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(.init(title: "New Library…",
                           action: #selector(NSDocumentController.newDocument(_:)),
                           keyEquivalent: "n"))
        let newAlbum = NSMenuItem(title: "New Album…",
                                  action: #selector(LibraryViewController.newAlbumFromMenu(_:)),
                                  keyEquivalent: "N")  // capital → Cmd+Shift+N
        menu.addItem(newAlbum)
        menu.addItem(.init(title: "Open Library…",
                           action: #selector(NSDocumentController.openDocument(_:)),
                           keyEquivalent: "o"))
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(.init(title: "Clear Menu",
                                 action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                 keyEquivalent: ""))
        openRecent.submenu = recentMenu
        menu.addItem(openRecent)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Import…",
                           action: #selector(LibraryWindowController.importFromMenu(_:)),
                           keyEquivalent: "i"))
        let importCard = NSMenuItem(title: "Import from Camera or Card…",
                                    action: #selector(LibraryWindowController.importFromCardFromMenu(_:)),
                                    keyEquivalent: "i")
        importCard.keyEquivalentModifierMask = [.command, .shift]   // ⇧⌘I
        menu.addItem(importCard)
        menu.addItem(.separator())
        // Export the current grid selection out of the library. Actions reach
        // LibraryViewController through the responder chain and self-validate:
        // "Export Photos…" disables with no selection, "Export Originals" only
        // enables when the selection carries a RAW / sidecar (mirrors the
        // right-click context menu, which is the other entry point). ⇧⌘E is
        // Apple's house style for Export across iWork / Photos.
        let exportMasters = NSMenuItem(title: "Export Photos…",
                                       action: #selector(LibraryViewController.exportMastersFromMenu(_:)),
                                       keyEquivalent: "e")
        exportMasters.keyEquivalentModifierMask = [.command, .shift]   // ⇧⌘E
        menu.addItem(exportMasters)
        menu.addItem(.init(title: "Export Originals (with RAW)…",
                           action: #selector(LibraryViewController.exportOriginalsFromMenu(_:)),
                           keyEquivalent: ""))
        menu.addItem(.separator())
        // Re-derive thumbnails / EXIF / content hashes from the originals on
        // disk. Lives in File rather than View because it's a library-scoped
        // data operation, not a window-scoped display setting.
        menu.addItem(.init(title: "Rebuild Library Data…",
                           action: #selector(LibraryWindowController.rebuildLibraryDataFromMenu(_:)),
                           keyEquivalent: ""))
        // Static analysis of the library — equipment, time-of-capture and daily
        // activity breakdowns. Opens its own window off the active library.
        let stats = NSMenuItem(title: "Library Statistics…",
                               action: #selector(LibraryWindowController.showStatisticsFromMenu(_:)),
                               keyEquivalent: "i")
        stats.keyEquivalentModifierMask = [.command, .option]   // ⌥⌘I
        menu.addItem(stats)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w"))
        item.submenu = menu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        // Undo / Redo drive the active window's undo manager via the responder
        // chain (LibraryWindowController vends it). Titles auto-update to
        // "Undo Favorite", "Redo Move to Trash", etc. through AppKit's standard
        // undo-menu management once the actions carry NSUndoManager action names.
        menu.addItem(.init(title: "Undo",
                           action: Selector(("undo:")),
                           keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]   // ⇧⌘Z
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Select All",
                           action: #selector(NSResponder.selectAll(_:)),
                           keyEquivalent: "a"))
        item.submenu = menu
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        // Cmd+Ctrl+S — Apple's standard sidebar-toggle shortcut (Mail, Notes,
        // Finder, Music all use it). Action goes through the responder chain
        // to the active NSSplitViewController.
        let toggleSidebar = NSMenuItem(title: "Hide Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(toggleSidebar)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Larger Thumbnails",
                           action: #selector(LibraryWindowController.zoomIn(_:)),
                           keyEquivalent: "+"))
        menu.addItem(.init(title: "Smaller Thumbnails",
                           action: #selector(LibraryWindowController.zoomOut(_:)),
                           keyEquivalent: "-"))
        menu.addItem(.separator())
        // Sort By → capture-date direction. Items carry a checkmark for the
        // active order via LibraryViewController.validateMenuItem; tag 0 = newest,
        // tag 1 = oldest. Actions reach the library VC through the responder chain.
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        let newestFirst = NSMenuItem(title: "Newest First",
                                     action: #selector(LibraryViewController.sortFromMenu(_:)),
                                     keyEquivalent: "")
        newestFirst.tag = 0
        let oldestFirst = NSMenuItem(title: "Oldest First",
                                     action: #selector(LibraryViewController.sortFromMenu(_:)),
                                     keyEquivalent: "")
        oldestFirst.tag = 1
        sortMenu.addItem(newestFirst)
        sortMenu.addItem(oldestFirst)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        item.submenu = menu
        return item
    }

    private static func shareMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Share")
        // Read-only web gallery for the active library. Routed to the library
        // window controller through the responder chain (so it disables itself
        // when no library is open). The panel handles start/stop, the access
        // token, and the Cloudflare Tunnel hint.
        menu.addItem(.init(title: "Web Server…",
                           action: #selector(LibraryWindowController.showWebServerFromMenu(_:)),
                           keyEquivalent: ""))
        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(.init(title: "Minimize",
                           action: #selector(NSWindow.miniaturize(_:)),
                           keyEquivalent: "m"))
        menu.addItem(.init(title: "Zoom",
                           action: #selector(NSWindow.zoom(_:)),
                           keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: ""))
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
