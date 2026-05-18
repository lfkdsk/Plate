import AppKit

/// Editorial dark welcome — two columns: hero (display serif + italic lead +
/// mono-caps version + two action cards) and a Recent list. Closes when any
/// library window becomes key (see AppDelegate's observer).
final class WelcomeWindowController: NSWindowController {

    init() {
        let initial = NSRect(x: 0, y: 0, width: 780, height: 480)
        let window = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Plate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = PlateColor.primary
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.contentViewController = WelcomeViewController()

        let visible = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(NSRect(
            x: visible.midX - initial.width / 2,
            y: visible.midY - initial.height / 2,
            width: initial.width,
            height: initial.height
        ), display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - View controller

final class WelcomeViewController: NSViewController,
                                   NSTableViewDataSource,
                                   NSTableViewDelegate {

    private var recents: [URL] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No recent libraries.")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
        root.wantsLayer = true
        root.layer?.backgroundColor = PlateColor.primary.cgColor
        view = root

        let hero = makeHeroColumn()
        let recents = makeRecentsColumn()
        let divider = HairlineView(axis: .vertical)

        for v in [hero, divider, recents] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hero.topAnchor.constraint(equalTo: root.topAnchor),
            hero.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hero.widthAnchor.constraint(equalToConstant: 380),

            divider.leadingAnchor.constraint(equalTo: hero.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48),
            divider.widthAnchor.constraint(equalToConstant: 1),

            recents.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            recents.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            recents.topAnchor.constraint(equalTo: root.topAnchor),
            recents.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadRecents()
    }

    private func reloadRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
        table.reloadData()
        emptyLabel.isHidden = !recents.isEmpty
    }

    // MARK: - Columns

    private func makeHeroColumn() -> NSView {
        let v = NSView()

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            icon.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            icon.contentTintColor = PlateColor.accent
        }

        // Display serif title.
        let title = NSTextField(labelWithString: "Welcome to Plate")
        title.font = PlateFont.serif(28, weight: .semibold)
        title.textColor = PlateColor.textPrimary

        // Italic-serif "lead" — one per view max.
        let tagline = NSTextField(labelWithString: "A quiet library for Hasselblad RAW.")
        tagline.font = PlateFont.serif(14, italic: true)
        tagline.textColor = PlateColor.textMuted

        // Mono caps for the version line.
        let version = NSTextField(labelWithString: "VERSION \(Self.versionString.uppercased())")
        version.font = PlateFont.mono(10, weight: .medium)
        version.textColor = PlateColor.textFaint
        let kerning = NSMutableAttributedString(string: version.stringValue)
        kerning.addAttribute(.kern, value: 1.2,
                              range: NSRange(location: 0, length: kerning.length))
        kerning.addAttributes([
            .font: version.font!,
            .foregroundColor: version.textColor!,
        ], range: NSRange(location: 0, length: kerning.length))
        version.attributedStringValue = kerning

        let newCard = WelcomeActionCard(
            symbolName: "plus.square.fill",
            title: "New Library",
            subtitle: "Start a fresh .plate bundle.",
            kind: .primary
        ) { [weak self] in
            NSDocumentController.shared.newDocument(self)
        }
        let openCard = WelcomeActionCard(
            symbolName: "folder",
            title: "Open Library",
            subtitle: "Browse for a .plate on disk.",
            kind: .secondary
        ) { [weak self] in
            NSDocumentController.shared.openDocument(self)
        }

        for sub in [icon, title, tagline, version, newCard, openCard] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 60),
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),

            tagline.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            tagline.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),

            version.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 10),
            version.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),

            newCard.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 32),
            newCard.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            newCard.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
            newCard.heightAnchor.constraint(equalToConstant: 64),

            openCard.topAnchor.constraint(equalTo: newCard.bottomAnchor, constant: 8),
            openCard.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            openCard.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
            openCard.heightAnchor.constraint(equalToConstant: 64),
        ])
        return v
    }

    private func makeRecentsColumn() -> NSView {
        let v = NSView()

        let header = NSTextField(labelWithString: "RECENT")
        header.font = PlateFont.mono(10, weight: .semibold)
        header.textColor = PlateColor.textSubtle
        let attr = NSMutableAttributedString(string: "RECENT")
        attr.addAttributes([
            .font: header.font!,
            .foregroundColor: header.textColor!,
            .kern: 1.6,
        ], range: NSRange(location: 0, length: attr.length))
        header.attributedStringValue = attr

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        if #available(macOS 11.0, *) { table.style = .plain }
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedRecent(_:))
        table.action = #selector(openSelectedRecent(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        emptyLabel.font = PlateFont.serif(13, italic: true)
        emptyLabel.textColor = PlateColor.textFaint
        emptyLabel.alignment = .center

        for sub in [header, scrollView, emptyLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 76),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -28),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -36),

            emptyLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    // MARK: - Recent table

    @objc private func openSelectedRecent(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < recents.count else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: recents[row],
            display: true
        ) { [weak self] doc, _, error in
            if doc == nil, let error = error {
                NSAlert(error: error).runModal()
                self?.reloadRecents()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = RecentRowCell()
        cell.configure(url: recents[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RecentRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 52 }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}

// MARK: - Action card

private enum CardKind { case primary, secondary }

private final class WelcomeActionCard: NSView {

    private let onClick: () -> Void
    private let kind: CardKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressed = false  { didSet { updateAppearance() } }

    init(symbolName: String,
         title: String,
         subtitle: String,
         kind: CardKind,
         onClick: @escaping () -> Void)
    {
        self.onClick = onClick
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3      // Small radius — InkType "--ink-radius-sm"

        iconView.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbolName,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
        }

        titleLabel.stringValue = title
        titleLabel.font = PlateFont.body(13, weight: .semibold)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = PlateFont.body(11)
        subtitleLabel.lineBreakMode = .byTruncatingTail

        for v in [iconView, titleLabel, subtitleLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        switch kind {
        case .primary:
            let base = PlateColor.accent
            let bg: NSColor = isPressed
                ? (base.blended(withFraction: 0.18, of: .black) ?? base)
                : (isHovering ? (base.blended(withFraction: 0.08, of: .white) ?? base) : base)
            layer?.backgroundColor = bg.cgColor
            layer?.borderWidth = 0
            titleLabel.textColor = NSColor(hex: 0xFFF7EE)
            subtitleLabel.textColor = NSColor(hex: 0xFFF7EE).withAlphaComponent(0.85)
            if #available(macOS 11.0, *) {
                iconView.contentTintColor = NSColor(hex: 0xFFF7EE)
            }
        case .secondary:
            let bg: NSColor
            if isPressed         { bg = PlateColor.raised }
            else if isHovering   { bg = PlateColor.surface }
            else                 { bg = .clear }
            layer?.backgroundColor = bg.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = PlateColor.hairline.cgColor
            titleLabel.textColor = PlateColor.textPrimary
            subtitleLabel.textColor = PlateColor.textMuted
            if #available(macOS 11.0, *) {
                iconView.contentTintColor = PlateColor.accent
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}

// MARK: - Recent row cell

private final class RecentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 6, dy: 2)
        PlateColor.selected.setFill()
        NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3).fill()
    }
}

private final class RecentRowCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            iconView.image = NSImage(systemSymbolName: "photo.stack",
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            iconView.contentTintColor = PlateColor.accent
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = PlateFont.serif(14)
        nameLabel.textColor = PlateColor.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle

        pathLabel.font = PlateFont.mono(9)
        pathLabel.textColor = PlateColor.textFaint
        pathLabel.lineBreakMode = .byTruncatingMiddle

        for v in [iconView, nameLabel, pathLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            pathLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
    }

    func configure(url: URL) {
        nameLabel.stringValue = url.deletingPathExtension().lastPathComponent
        let abbreviated = (url.path as NSString).abbreviatingWithTildeInPath
        let attr = NSMutableAttributedString(string: abbreviated.uppercased())
        attr.addAttributes([
            .font: pathLabel.font!,
            .foregroundColor: pathLabel.textColor!,
            .kern: 0.4,
        ], range: NSRange(location: 0, length: attr.length))
        pathLabel.attributedStringValue = attr
    }
}

// MARK: - Hairline divider

private final class HairlineView: NSView {
    enum Axis { case horizontal, vertical }

    init(axis: Axis) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PlateColor.hairline.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}
