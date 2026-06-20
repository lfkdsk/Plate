import AppKit
import ImageIO
import PlateCore

/// Photos-style "import from camera / SD card" sheet. Shows the importable
/// photos found on a mounted volume (or any folder) as a thumbnail grid,
/// flags the ones already in the library by SHA-256, lets the user hide those
/// and pick what to bring in, then runs the standard import pipeline.
///
/// Present with `ImportPickerViewController.present(from:library:pairs:sourceName:onImported:)`.
final class ImportPickerViewController: NSViewController {

    private struct Candidate {
        let pair: AssetPair
        var alreadyImported = false
        var selected = false
        var thumb: NSImage?
        var thumbRequested = false
    }

    private let library: PlateLibrary
    private var candidates: [Candidate]
    private let sourceName: String
    private let onImported: () -> Void

    /// Indices into `candidates` for the rows currently shown (after the
    /// hide-already-imported filter).
    private var displayedIndices: [Int] = []
    private var hideImported = true
    private var checking = true   // duplicate scan in progress

    private let titleLabel = NSTextField(labelWithString: "")
    private let hideToggle = NSButton(checkboxWithTitle: "Hide Already Imported", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()

    private static let thumbQueue = DispatchQueue(label: "plate.import-thumbs", qos: .userInitiated, attributes: .concurrent)

    // MARK: - Presentation

    /// Build the picker for `pairs` and present it as a sheet on `presenter`.
    /// No-op when `pairs` is empty.
    static func present(from presenter: NSViewController,
                        library: PlateLibrary,
                        pairs: [AssetPair],
                        sourceName: String,
                        onImported: @escaping () -> Void) {
        guard !pairs.isEmpty else { return }
        let vc = ImportPickerViewController(library: library,
                                            pairs: pairs,
                                            sourceName: sourceName,
                                            onImported: onImported)
        presenter.presentAsSheet(vc)
    }

    init(library: PlateLibrary, pairs: [AssetPair], sourceName: String, onImported: @escaping () -> Void) {
        self.library = library
        self.candidates = pairs.map { Candidate(pair: $0) }
        self.sourceName = sourceName
        self.onImported = onImported
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = PlateColor.primary.cgColor
        view = root

        titleLabel.font = PlateFont.serif(16, weight: .semibold)
        titleLabel.textColor = PlateColor.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        hideToggle.target = self
        hideToggle.action = #selector(toggleHide(_:))
        hideToggle.state = hideImported ? .on : .off
        hideToggle.contentTintColor = PlateColor.textMuted
        hideToggle.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 150)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ImportCandidateItem.self,
                                forItemWithIdentifier: ImportCandidateItem.identifier)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        collectionView.addGestureRecognizer(click)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        selectAllButton.target = self
        selectAllButton.action = #selector(toggleSelectAll(_:))
        selectAllButton.bezelStyle = .rounded
        selectAllButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = PlateFont.mono(11)
        statusLabel.textColor = PlateColor.textMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        importButton.target = self
        importButton.action = #selector(performImport(_:))
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"        // Return
        importButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [titleLabel, hideToggle, scrollView, selectAllButton, statusLabel, progress, cancelButton, importButton] {
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            hideToggle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            hideToggle.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            selectAllButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            selectAllButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            progress.leadingAnchor.constraint(equalTo: selectAllButton.trailingAnchor, constant: 14),
            progress.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            importButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            importButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.setContentSize(NSSize(width: 760, height: 560))
        rebuildDisplayed()
        startDuplicateScan()
    }

    // MARK: - Duplicate scan

    private func startDuplicateScan() {
        checking = true
        progress.startAnimation(nil)
        updateChrome()
        let pairs = candidates.map { $0.pair }
        let lib = library
        Self.thumbQueue.async { [weak self] in
            let existing = lib.existingContentHashes()
            var imported = [Bool](repeating: false, count: pairs.count)
            for (i, pair) in pairs.enumerated() {
                if let hash = try? lib.contentHash(of: pair.primary) {
                    imported[i] = existing.contains(hash)
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for i in self.candidates.indices where i < imported.count {
                    self.candidates[i].alreadyImported = imported[i]
                    self.candidates[i].selected = !imported[i]   // default: new ones selected
                }
                self.checking = false
                self.progress.stopAnimation(nil)
                self.rebuildDisplayed()
                self.updateChrome()
            }
        }
    }

    // MARK: - Filtering / chrome

    private func rebuildDisplayed() {
        displayedIndices = candidates.indices.filter { hideImported ? !candidates[$0].alreadyImported : true }
        collectionView.reloadData()
    }

    private var selectedCount: Int { candidates.filter { $0.selected }.count }
    private var newCount: Int { candidates.filter { !$0.alreadyImported }.count }

    private func updateChrome() {
        let total = candidates.count
        titleLabel.stringValue = "Import from \(sourceName)"
        if checking {
            statusLabel.stringValue = "Checking \(total) photos for duplicates…"
            importButton.isEnabled = false
            selectAllButton.isEnabled = false
            hideToggle.isEnabled = false
        } else {
            let dupes = total - newCount
            statusLabel.stringValue = "\(total) photos · \(newCount) new" + (dupes > 0 ? " · \(dupes) already imported" : "")
            importButton.isEnabled = selectedCount > 0
            importButton.title = selectedCount > 0 ? "Import \(selectedCount)" : "Import"
            selectAllButton.isEnabled = !displayedIndices.isEmpty
            let allSelected = !displayedIndices.isEmpty && displayedIndices.allSatisfy { candidates[$0].selected }
            selectAllButton.title = allSelected ? "Deselect All" : "Select All"
            hideToggle.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func toggleHide(_ sender: NSButton) {
        hideImported = (sender.state == .on)
        rebuildDisplayed()
        updateChrome()
    }

    @objc private func toggleSelectAll(_ sender: NSButton) {
        let allSelected = !displayedIndices.isEmpty && displayedIndices.allSatisfy { candidates[$0].selected }
        for i in displayedIndices where !candidates[i].alreadyImported {
            candidates[i].selected = !allSelected
        }
        collectionView.reloadData()
        updateChrome()
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let path = collectionView.indexPathForItem(at: point),
              path.item < displayedIndices.count else { return }
        let ci = displayedIndices[path.item]
        guard !candidates[ci].alreadyImported else { return }   // imported tiles aren't selectable
        candidates[ci].selected.toggle()
        collectionView.reloadItems(at: [path])
        updateChrome()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(self)
    }

    @objc private func performImport(_ sender: Any?) {
        let pairs = candidates.filter { $0.selected }.map { $0.pair }
        guard !pairs.isEmpty else { return }

        checking = true   // reuse the "busy" lockout
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(pairs.count)
        progress.doubleValue = 0
        progress.startAnimation(nil)
        importButton.isEnabled = false
        cancelButton.isEnabled = false
        selectAllButton.isEnabled = false
        hideToggle.isEnabled = false
        statusLabel.stringValue = "Importing 0 / \(pairs.count)…"

        let lib = library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? lib.importPairs(pairs) { completed, total in
                DispatchQueue.main.async {
                    self?.progress.doubleValue = Double(completed)
                    self?.statusLabel.stringValue = "Importing \(completed) / \(total)…"
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progress.stopAnimation(nil)
                self.onImported()
                if let result = result, !result.failures.isEmpty {
                    self.presentFailureSummary(result)
                }
                self.dismiss(self)
            }
        }
    }

    private func presentFailureSummary(_ result: PlateLibrary.ImportResult) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Imported \(result.imported.count), \(result.failures.count) couldn't be read"
        alert.informativeText = result.failures.prefix(5)
            .map { "  • " + $0.source.lastPathComponent }
            .joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Thumbnails

    private func requestThumbnail(forDisplayed displayItem: Int) {
        guard displayItem < displayedIndices.count else { return }
        let ci = displayedIndices[displayItem]
        guard !candidates[ci].thumbRequested, candidates[ci].thumb == nil else { return }
        candidates[ci].thumbRequested = true
        let url = candidates[ci].pair.primary
        Self.thumbQueue.async { [weak self] in
            let img = Self.decodeThumb(url: url, maxPixel: 300)
            DispatchQueue.main.async {
                guard let self = self,
                      ci < self.candidates.count else { return }
                self.candidates[ci].thumb = img
                // Refresh the cell if it's still on screen for this candidate.
                if let row = self.displayedIndices.firstIndex(of: ci) {
                    let path = IndexPath(item: row, section: 0)
                    if self.collectionView.item(at: path) != nil {
                        self.collectionView.reloadItems(at: [path])
                    }
                }
            }
        }
    }

    private static func decodeThumb(url: URL, maxPixel: Int) -> NSImage? {
        // Movies have no ImageIO source — pull a poster frame so video candidates
        // aren't blank tiles in the picker.
        if AssetKind.classify(pathExtension: url.pathExtension) == .video {
            guard let cg = ThumbnailService.videoPosterFrame(from: url, maxPixel: maxPixel) else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Data source

extension ImportPickerViewController: NSCollectionViewDataSource {
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedIndices.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ImportCandidateItem.identifier, for: indexPath) as! ImportCandidateItem
        let ci = displayedIndices[indexPath.item]
        let c = candidates[ci]
        item.configure(thumbnail: c.thumb,
                       selected: c.selected,
                       alreadyImported: c.alreadyImported,
                       hasRaw: !c.pair.raws.isEmpty,
                       mediaType: c.pair.mediaType)
        if c.thumb == nil { requestThumbnail(forDisplayed: indexPath.item) }
        return item
    }
}

// MARK: - Candidate cell

private final class ImportCandidateItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ImportCandidate")

    private let thumb = NSImageView()
    private let dim = CALayer()
    private let checkBg = NSView()
    private let check = NSImageView()
    private let importedBadge = NSTextField(labelWithString: "IMPORTED")
    private let rawBadge = NSTextField(labelWithString: "RAW")
    /// Bottom-right marker for movie ("VIDEO") and Live Photo ("LIVE") candidates.
    private let typeBadge = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = PlateColor.surface.cgColor
        view = v

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb)

        dim.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dim.isHidden = true
        v.layer?.addSublayer(dim)

        // Selection check — filled accent circle, top-right.
        checkBg.wantsLayer = true
        checkBg.layer?.cornerRadius = 11
        checkBg.layer?.backgroundColor = PlateColor.accent.cgColor
        checkBg.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        checkBg.layer?.borderWidth = 1.5
        checkBg.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(checkBg)
        check.imageScaling = .scaleProportionallyDown
        check.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            check.contentTintColor = .white
        }
        checkBg.addSubview(check)

        importedBadge.font = PlateFont.mono(8, weight: .semibold)
        importedBadge.textColor = PlateColor.textPrimary
        importedBadge.alignment = .center
        importedBadge.wantsLayer = true
        importedBadge.drawsBackground = true
        importedBadge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        importedBadge.layer?.cornerRadius = 2
        importedBadge.isHidden = true
        importedBadge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(importedBadge)

        rawBadge.font = PlateFont.mono(8, weight: .semibold)
        rawBadge.textColor = PlateColor.textPrimary
        rawBadge.alignment = .center
        rawBadge.wantsLayer = true
        rawBadge.drawsBackground = true
        rawBadge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        rawBadge.layer?.cornerRadius = 2
        rawBadge.isHidden = true
        rawBadge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(rawBadge)

        typeBadge.font = PlateFont.mono(8, weight: .semibold)
        typeBadge.textColor = PlateColor.textPrimary
        typeBadge.alignment = .center
        typeBadge.wantsLayer = true
        typeBadge.drawsBackground = true
        typeBadge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        typeBadge.layer?.cornerRadius = 2
        typeBadge.isHidden = true
        typeBadge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(typeBadge)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: v.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            checkBg.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            checkBg.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            checkBg.widthAnchor.constraint(equalToConstant: 22),
            checkBg.heightAnchor.constraint(equalToConstant: 22),
            check.centerXAnchor.constraint(equalTo: checkBg.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: checkBg.centerYAnchor),

            importedBadge.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            importedBadge.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            importedBadge.heightAnchor.constraint(equalToConstant: 16),
            importedBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            rawBadge.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            rawBadge.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
            rawBadge.heightAnchor.constraint(equalToConstant: 14),
            rawBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            typeBadge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            typeBadge.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
            typeBadge.heightAnchor.constraint(equalToConstant: 14),
            typeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        dim.frame = view.bounds
    }

    func configure(thumbnail: NSImage?, selected: Bool, alreadyImported: Bool,
                   hasRaw: Bool, mediaType: MediaType = .image) {
        thumb.image = thumbnail
        dim.isHidden = !alreadyImported
        importedBadge.isHidden = !alreadyImported
        rawBadge.isHidden = !hasRaw
        switch mediaType {
        case .image:     typeBadge.isHidden = true
        case .video:     typeBadge.stringValue = "VIDEO"; typeBadge.isHidden = false
        case .livePhoto: typeBadge.stringValue = "LIVE";  typeBadge.isHidden = false
        }
        // Selection check hidden for already-imported tiles (not selectable).
        checkBg.isHidden = alreadyImported || !selected
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumb.image = nil
        dim.isHidden = true
        importedBadge.isHidden = true
        rawBadge.isHidden = true
        typeBadge.isHidden = true
        checkBg.isHidden = true
    }
}
