import AppKit

final class AssetItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AssetItem")

    private let thumbView = NSImageView()
    private let hoverOverlay = CALayer()
    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let bigOverlayLabel = NSTextField(labelWithString: "")
    private let bigOverlayDimmer = CALayer()
    private let favoriteButton = NSButton()
    /// Local state mirroring what the data source supplied — needed so the
    /// hover handler knows whether to show an outlined heart (not-yet-favorite,
    /// click to add) or keep the filled heart (already favorite, always visible).
    private var isFavorited = false
    private var isHovered = false
    /// Aggregate (Year / Month) tiles don't expose the favorite affordance —
    /// clicking would imply favoriting the whole period.
    private var isAggregateTile = false
    /// Fires when the user clicks the heart button on this tile. The data
    /// source flips the asset's favorite state in PlateCore and reloads.
    var onToggleFavorite: (() -> Void)?

    override func loadView() {
        let v = HoverTrackingView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 3
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = PlateColor.surface.cgColor
        // Cream-coloured ring rather than the accent orange — orange every time
        // you touch a tile reads as a warning indicator. Save accent for things
        // that actually warrant attention (primary actions, current page).
        v.layer?.borderColor = PlateColor.textPrimary.cgColor
        v.layer?.borderWidth = 0
        v.onHoverChange = { [weak self] hovering in
            self?.isHovered = hovering
            self?.updateHoverHighlight(hovering: hovering)
            self?.updateFavoriteButton()
        }
        // NSButton's normal target/action is unreliable when the button lives
        // inside an NSCollectionView item — the collection view's selection
        // machinery eats the mouseDown before the button can track it. We do
        // the hit testing ourselves on the cell's root view (see
        // HoverTrackingView.mouseDown) and fire onToggleFavorite directly.
        v.favoriteHitTarget = { [weak self] in self?.favoriteButton }
        v.onFavoriteTap = { [weak self] in self?.handleFavoriteClick(nil) }
        view = v

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.imageAlignment = .alignCenter
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            thumbView.topAnchor.constraint(equalTo: v.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        // Soft hover overlay drawn on top of the image but under the border.
        hoverOverlay.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hoverOverlay.opacity = 0
        v.layer?.addSublayer(hoverOverlay)

        // Top-left format badge — "JPEG", "HEIF + RAW", etc. Mono caps in a
        // small dark pill so it stays legible regardless of photo content.
        badgePill.wantsLayer = true
        badgePill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badgePill.layer?.cornerRadius = 2
        badgePill.translatesAutoresizingMaskIntoConstraints = false
        badgePill.isHidden = true
        v.addSubview(badgePill)

        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgePill.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            badgePill.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            badgePill.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),

            badgeLabel.leadingAnchor.constraint(equalTo: badgePill.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgePill.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgePill.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgePill.bottomAnchor, constant: -2),
        ])

        // Favorite affordance — clickable heart in the top-right corner.
        // Visible:
        //   - always when the asset is already a favorite (filled red heart)
        //   - on hover when it's NOT yet a favorite (outlined white heart, click
        //     to favorite it without leaving the grid — Apple Photos pattern).
        // Drop shadow keeps it legible regardless of underlying photo content.
        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .smallSquare
        favoriteButton.title = ""
        favoriteButton.imageScaling = .scaleProportionallyDown
        favoriteButton.target = self
        favoriteButton.action = #selector(handleFavoriteClick(_:))
        favoriteButton.isHidden = true
        favoriteButton.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(favoriteButton)
        NSLayoutConstraint.activate([
            favoriteButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            favoriteButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            favoriteButton.widthAnchor.constraint(equalToConstant: 22),
            favoriteButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Aggregate-mode overlay: dim layer + centred large serif label.
        // Both are hidden in normal photo tiles and only show when the data
        // source supplies a `bigOverlay` string (Year / Month mode).
        bigOverlayDimmer.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        bigOverlayDimmer.isHidden = true
        v.layer?.addSublayer(bigOverlayDimmer)

        bigOverlayLabel.alignment = .center
        bigOverlayLabel.lineBreakMode = .byTruncatingTail
        bigOverlayLabel.isHidden = true
        bigOverlayLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bigOverlayLabel)
        NSLayoutConstraint.activate([
            bigOverlayLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            bigOverlayLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            bigOverlayLabel.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 12),
            bigOverlayLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hoverOverlay.frame = view.bounds
        bigOverlayDimmer.frame = view.bounds
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        let active = isSelected || highlightState == .forSelection
        let layer = view.layer
        // Apple-Photos style: 2px accent ring (no thick slab).
        layer?.borderWidth = active ? 2 : 0
    }

    private func updateHoverHighlight(hovering: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        hoverOverlay.opacity = hovering ? 1 : 0
        CATransaction.commit()
    }

    func configure(thumbnailURL: URL?,
                   formatBadge: String?,
                   bigOverlay: String? = nil,
                   isFavorite: Bool = false)
    {
        thumbView.image = thumbnailURL.flatMap { NSImage(contentsOf: $0) }
        isFavorited = isFavorite
        // Aggregate cards carry a `bigOverlay` label — they don't get the
        // favorite button (would be misleading and the click handler is wired
        // to a single Asset anyway).
        isAggregateTile = (bigOverlay != nil && !(bigOverlay?.isEmpty ?? true))
        updateFavoriteButton()

        if let text = formatBadge, !text.isEmpty {
            let attr = NSMutableAttributedString(string: text)
            attr.addAttributes([
                .font: PlateFont.mono(9, weight: .medium),
                .foregroundColor: PlateColor.textPrimary,
                .kern: 0.6,
            ], range: NSRange(location: 0, length: attr.length))
            badgeLabel.attributedStringValue = attr
            badgePill.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgePill.isHidden = true
        }

        if let big = bigOverlay, !big.isEmpty {
            // Large serif period label (Year "2024" or "April 2026"), white with
            // a soft drop shadow so it stays legible over any photo content.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attr = NSAttributedString(string: big, attributes: [
                .font: PlateFont.serif(34, weight: .semibold),
                .foregroundColor: NSColor.white,
                .shadow: shadow,
            ])
            bigOverlayLabel.attributedStringValue = attr
            bigOverlayLabel.isHidden = false
            bigOverlayDimmer.isHidden = false
        } else {
            bigOverlayLabel.stringValue = ""
            bigOverlayLabel.isHidden = true
            bigOverlayDimmer.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbView.image = nil
        view.layer?.borderWidth = 0
        hoverOverlay.opacity = 0
        badgeLabel.stringValue = ""
        badgePill.isHidden = true
        bigOverlayLabel.stringValue = ""
        bigOverlayLabel.isHidden = true
        bigOverlayDimmer.isHidden = true
        favoriteButton.isHidden = true
        isFavorited = false
        isHovered = false
        isAggregateTile = false
        onToggleFavorite = nil
    }

    /// Render the heart button based on current favorited/hovered state.
    /// Visible whenever already favorited OR currently hovered (and not an
    /// aggregate card). Symbol + tint swap between outlined-white (call to
    /// action) and filled-red (status).
    private func updateFavoriteButton() {
        guard #available(macOS 11.0, *) else {
            favoriteButton.isHidden = true
            return
        }
        if isAggregateTile {
            favoriteButton.isHidden = true
            return
        }
        let shouldShow = isFavorited || isHovered
        favoriteButton.isHidden = !shouldShow
        guard shouldShow else { return }
        let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let symbol = isFavorited ? "heart.fill" : "heart"
        favoriteButton.image = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: nil)?
            .withSymbolConfiguration(conf)
        favoriteButton.contentTintColor = isFavorited ? PlateColor.accent : .white
    }

    @objc private func handleFavoriteClick(_ sender: Any?) {
        onToggleFavorite?()
    }
}

/// NSCollectionView items don't get hover events out of the box — track them on
/// the item's root view via a tracking area and bubble up to the controller.
/// Also handles clicks on the favorite heart, since NSButton's action doesn't
/// fire reliably inside an NSCollectionViewItem.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    /// Closure returning the favorite button view (so we can read its current
    /// frame + visibility on each click). Set by AssetItemView in loadView.
    var favoriteHitTarget: (() -> NSView?)?
    /// Fired when the user clicks inside the favorite button's frame.
    var onFavoriteTap: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        // Intercept plain clicks landing on the favorite-heart frame and fire
        // the toggle callback directly. Modifier-held clicks (shift / cmd) are
        // passed through so range-select and multi-select still work even when
        // they happen to land on the heart.
        if event.modifierFlags.intersection([.shift, .command]).isEmpty,
           let target = favoriteHitTarget?(),
           !target.isHidden,
           target.superview === self
        {
            let point = convert(event.locationInWindow, from: nil)
            if target.frame.contains(point) {
                onFavoriteTap?()
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Make the heart respond to the *first* click on an unfocused window too —
    /// without this, the user would have to click once to bring the window to
    /// front and a second time to toggle the favorite.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
