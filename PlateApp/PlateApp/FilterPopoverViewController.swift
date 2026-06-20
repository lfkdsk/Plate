import AppKit
import PlateCore

/// Photos-style dynamic filter popover. Builds a `SmartFilter` from its
/// controls and reports it via `onChange` whenever anything changes. The
/// heavy lifting — turning rules into SQL — lives in PlateCore's
/// `SmartFilter.compile()`; this view only assembles the rule set.
final class FilterPopoverViewController: NSViewController {

    /// Called with a freshly-built filter on every control change (including
    /// "Clear", which sends an empty filter).
    var onChange: ((SmartFilter) -> Void)?

    private let cameras: [String]
    private let lenses: [String]
    private let years: [Int]
    /// The filter to restore into the controls when the popover opens.
    private let initial: SmartFilter

    private let matchControl = NSSegmentedControl(labels: ["All", "Any"],
                                                  trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let favoritesCheck = NSButton(checkboxWithTitle: "Favorites", target: nil, action: nil)
    private let rawCheck = NSButton(checkboxWithTitle: "Has RAW", target: nil, action: nil)
    private let gpsCheck = NSButton(checkboxWithTitle: "Geotagged", target: nil, action: nil)
    private let mediaPopup = NSPopUpButton()
    private let cameraPopup = NSPopUpButton()
    private let lensPopup = NSPopUpButton()
    private let yearPopup = NSPopUpButton()
    private let isoPopup = NSPopUpButton()
    private let aperturePopup = NSPopUpButton()

    // Media-kind presets: display title → rule value (nil = "Any", no rule).
    private let mediaPresets: [(String, MediaType?)] = [
        ("Any", nil), ("Photos", .image), ("Videos", .video), ("Live Photos", .livePhoto),
    ]

    // Numeric presets: display title → rule value (nil = "Any", no rule).
    private let isoPresets: [(String, Double?)] = [
        ("Any", nil), ("≥ 100", 100), ("≥ 400", 400), ("≥ 800", 800),
        ("≥ 1600", 1600), ("≥ 3200", 3200), ("≥ 6400", 6400),
    ]
    private let aperturePresets: [(String, Double?)] = [
        ("Any", nil), ("≤ f/1.4", 1.4), ("≤ f/2", 2), ("≤ f/2.8", 2.8),
        ("≤ f/4", 4), ("≤ f/5.6", 5.6), ("≤ f/8", 8),
    ]

    init(cameras: [String], lenses: [String], years: [Int], current: SmartFilter) {
        self.cameras = cameras
        self.lenses = lenses
        self.years = years
        self.initial = current
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        // Width holds the label column (92) + spacing + a fixed 200pt popup,
        // plus the stack's 16pt side insets. Height fits the rows snugly.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 444))
        view = root

        matchControl.selectedSegment = 0
        matchControl.target = self
        matchControl.action = #selector(controlChanged)

        for check in [favoritesCheck, rawCheck, gpsCheck] {
            check.target = self
            check.action = #selector(controlChanged)
        }

        configurePopup(mediaPopup, title: "Media", items: mediaPresets.map(\.0))
        configurePopup(cameraPopup, title: "Camera",
                       items: ["Any Camera"] + cameras)
        configurePopup(lensPopup, title: "Lens",
                       items: ["Any Lens"] + lenses)
        configurePopup(yearPopup, title: "Year",
                       items: ["Any Year"] + years.map(String.init))
        configurePopup(isoPopup, title: "Min ISO", items: isoPresets.map(\.0))
        configurePopup(aperturePopup, title: "Max Aperture", items: aperturePresets.map(\.0))

        let clearButton = NSButton(title: "Clear Filter", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded

        let matchRow = labeledRow("Match", matchControl)

        let stack = NSStackView(views: [
            sectionLabel("FILTER"),
            matchRow,
            spacer(4),
            favoritesCheck, rawCheck, gpsCheck,
            spacer(4),
            labeledRow("Media", mediaPopup),
            labeledRow("Camera", cameraPopup),
            labeledRow("Lens", lensPopup),
            labeledRow("Year", yearPopup),
            labeledRow("Min ISO", isoPopup),
            labeledRow("Max Aperture", aperturePopup),
            spacer(6),
            clearButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        restore(from: initial)
    }

    // MARK: - Build filter from controls

    @objc private func controlChanged() {
        onChange?(buildFilter())
    }

    @objc private func clearTapped() {
        restore(from: SmartFilter())
        onChange?(SmartFilter())
    }

    private func buildFilter() -> SmartFilter {
        var rules: [SmartFilter.Rule] = []
        if favoritesCheck.state == .on { rules.append(.isFavorite(true)) }
        if rawCheck.state == .on { rules.append(.hasRaw(true)) }
        if gpsCheck.state == .on { rules.append(.hasGPS(true)) }
        if let media = mediaPresets[safe: mediaPopup.indexOfSelectedItem]?.1 {
            rules.append(.mediaType(media))
        }
        if cameraPopup.indexOfSelectedItem > 0 {
            rules.append(.camera(.is(cameras[cameraPopup.indexOfSelectedItem - 1])))
        }
        if lensPopup.indexOfSelectedItem > 0 {
            rules.append(.lens(.is(lenses[lensPopup.indexOfSelectedItem - 1])))
        }
        if yearPopup.indexOfSelectedItem > 0 {
            rules.append(.captured(.year(years[yearPopup.indexOfSelectedItem - 1])))
        }
        if let iso = isoPresets[safe: isoPopup.indexOfSelectedItem]?.1 {
            rules.append(.iso(.atLeast(iso)))
        }
        if let f = aperturePresets[safe: aperturePopup.indexOfSelectedItem]?.1 {
            rules.append(.aperture(.atMost(f)))
        }
        let match: SmartFilter.Match = matchControl.selectedSegment == 1 ? .any : .all
        return SmartFilter(match: match, rules: rules)
    }

    /// Set control states from an existing filter (popover re-open) so it
    /// reflects what's currently applied.
    private func restore(from filter: SmartFilter) {
        matchControl.selectedSegment = (filter.match == .any) ? 1 : 0
        favoritesCheck.state = .off
        rawCheck.state = .off
        gpsCheck.state = .off
        mediaPopup.selectItem(at: 0)
        cameraPopup.selectItem(at: 0)
        lensPopup.selectItem(at: 0)
        yearPopup.selectItem(at: 0)
        isoPopup.selectItem(at: 0)
        aperturePopup.selectItem(at: 0)

        for rule in filter.rules {
            switch rule {
            case .isFavorite(true): favoritesCheck.state = .on
            case .hasRaw(true): rawCheck.state = .on
            case .hasGPS(true): gpsCheck.state = .on
            case .camera(.is(let v)):
                if let i = cameras.firstIndex(of: v) { cameraPopup.selectItem(at: i + 1) }
            case .lens(.is(let v)):
                if let i = lenses.firstIndex(of: v) { lensPopup.selectItem(at: i + 1) }
            case .captured(.year(let y)):
                if let i = years.firstIndex(of: y) { yearPopup.selectItem(at: i + 1) }
            case .iso(.atLeast(let v)):
                if let i = isoPresets.firstIndex(where: { $0.1 == v }) { isoPopup.selectItem(at: i) }
            case .aperture(.atMost(let v)):
                if let i = aperturePresets.firstIndex(where: { $0.1 == v }) { aperturePopup.selectItem(at: i) }
            case .mediaType(let t):
                if let i = mediaPresets.firstIndex(where: { $0.1 == t }) { mediaPopup.selectItem(at: i) }
            default:
                break
            }
        }
    }

    // MARK: - View helpers

    private func configurePopup(_ popup: NSPopUpButton, title: String, items: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = #selector(controlChanged)
        // Truncate an over-long selected title (e.g. a verbose lens name) inside
        // the button rather than letting the popup's intrinsic width balloon and
        // stretch the whole popover. The dropdown still lists full names.
        (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        popup.translatesAutoresizingMaskIntoConstraints = false
        // Fixed width so every row aligns and long content can't blow out the
        // layout (was greaterThanOrEqual → unbounded growth, the cause of the
        // popover stretching ~3× wide when a long lens name was present).
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = PlateFont.mono(10)
        label.textColor = PlateColor.textSubtle
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = PlateFont.body(12)
        label.textColor = PlateColor.textMuted
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
