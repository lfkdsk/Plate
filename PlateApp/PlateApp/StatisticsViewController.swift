import AppKit
import PlateCore

/// Static analysis of a library, à la PictorG's gallery stats: overview cards,
/// a GitHub-style daily-activity heatmap per year, time-of-capture column
/// charts, equipment breakdown bars, and an "On This Day" lookback. All values
/// come from `LibraryStatistics.compute` over the library's current snapshot.
final class StatisticsViewController: NSViewController {

    private let library: PlateLibrary
    private var assetsByID: [UUID: Asset] = [:]

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    init(library: PlateLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = PlateColor.primary.cgColor
        view = root

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true
        root.addSubview(scrollView)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = doc
        let clip = scrollView.contentView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 30
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 26),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -32),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -44),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
    }

    /// Tear down and re-assemble the whole view from a fresh snapshot. Called on
    /// first load and whenever the owning window re-opens the panel.
    func rebuild() {
        let assets = library.assets
        assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stats = LibraryStatistics.compute(from: assets)

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard stats.totalPhotos > 0 else {
            let empty = NSTextField(labelWithString: "No photos in this library yet.")
            empty.font = PlateFont.serif(16, italic: true)
            empty.textColor = PlateColor.textFaint
            addFullWidth(empty)
            return
        }

        addHeader(stats)
        addOverview(stats)
        addHeatmaps(stats)
        addActivity(stats)
        addFormats(stats)
        addEquipment(stats)
        addOnThisDay(stats)
    }

    // MARK: - Sections

    private func addHeader(_ s: LibraryStatistics) {
        var parts: [String] = ["\(Self.grouped(s.totalPhotos)) photos"]
        if let lo = s.earliestCapture, let hi = s.latestCapture {
            let f = Self.yearFormatter
            let loY = f.string(from: lo), hiY = f.string(from: hi)
            parts.append(loY == hiY ? loY : "\(loY)–\(hiY)")
        }
        if s.totalMegapixels >= 1 {
            parts.append(String(format: "%@ MP total", Self.grouped(Int(s.totalMegapixels.rounded()))))
        }
        let sub = NSTextField(labelWithString: parts.joined(separator: "  ·  "))
        sub.font = PlateFont.mono(11)
        sub.textColor = PlateColor.textSubtle
        addFullWidth(sub)
    }

    private func addOverview(_ s: LibraryStatistics) {
        var cards: [NSView] = [
            StatCardView(value: Self.grouped(s.totalPhotos), label: "Photos"),
            StatCardView(value: Self.grouped(s.favorites), label: "Favorites"),
            StatCardView(value: Self.grouped(s.withRaw), label: "With RAW"),
            StatCardView(value: Self.grouped(s.cameras.count), label: "Cameras"),
            StatCardView(value: Self.grouped(s.lenses.count), label: "Lenses"),
        ]
        if s.withGPS > 0 {
            cards.append(StatCardView(value: Self.grouped(s.withGPS), label: "Geotagged"))
        }
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 14
        addFullWidth(row)
    }

    private func addHeatmaps(_ s: LibraryStatistics) {
        guard !s.heatmap.isEmpty else { return }
        addSectionTitle("Activity")
        for year in s.heatmap {
            let caption = NSTextField(labelWithString:
                "\(year.year)  ·  \(Self.grouped(year.total)) photos  ·  peak \(year.max)/day")
            caption.font = PlateFont.mono(10)
            caption.textColor = PlateColor.textSubtle
            addFullWidth(caption)

            let heat = HeatmapYearView(data: year)
            // Leading-aligned at natural width — a full year (≈53 weeks) fits the
            // default/minimum window width; no horizontal scroll needed.
            contentStack.addArrangedSubview(heat)
        }
    }

    private func addActivity(_ s: LibraryStatistics) {
        addSectionTitle("When Photos Are Taken")
        addChart("By hour of day", ColumnChartView(rows: s.byHour, labelStride: 3))
        addChart("By day of week", ColumnChartView(rows: s.byWeekday, labelStride: 1))
        addChart("By month", ColumnChartView(rows: s.byMonth, labelStride: 1))
    }

    private func addChart(_ title: String, _ chart: NSView) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = PlateFont.mono(10)
        label.textColor = PlateColor.textSubtle
        addFullWidth(label)
        addFullWidth(chart)
    }

    private func addFormats(_ s: LibraryStatistics) {
        guard !s.formats.isEmpty else { return }
        addSectionTitle("Formats")
        // Always available (filename-derived). Half-width so it lines up with
        // the two-column equipment grid below it.
        let list = BarListView(title: "File Types", rows: s.formats, limit: 12)
        addFullWidth(twoColumn(list, nil))
    }

    private func addEquipment(_ s: LibraryStatistics) {
        addSectionTitle("Equipment")
        if s.withExif == 0 {
            let note = NSTextField(wrappingLabelWithString:
                "No camera metadata yet. Run File ▸ Rebuild Library Data to extract camera, lens and exposure info from your originals.")
            note.font = PlateFont.body(12)
            note.textColor = PlateColor.textMuted
            addFullWidth(note)
            return
        }
        let lists: [BarListView] = [
            BarListView(title: "Cameras", rows: s.cameras, limit: 10),
            BarListView(title: "Lenses", rows: s.lenses, limit: 10),
            BarListView(title: "Focal Lengths", rows: s.focalLengths, limit: 10),
            BarListView(title: "Apertures", rows: s.apertures, limit: 10),
            BarListView(title: "Shutter Speeds", rows: s.shutterSpeeds, limit: 10),
            BarListView(title: "ISO", rows: s.isos, limit: 10),
        ].filter { !$0.isEmptyList }
        // Two-column grid: pair lists into equal-width rows.
        var i = 0
        while i < lists.count {
            let left = lists[i]
            let right = (i + 1 < lists.count) ? lists[i + 1] : nil
            addFullWidth(twoColumn(left, right))
            i += 2
        }
    }

    private func addOnThisDay(_ s: LibraryStatistics) {
        let ids = Array(s.onThisDay.prefix(24))
        guard !ids.isEmpty else { return }
        addSectionTitle("On This Day")
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .top
        strip.spacing = 12
        for id in ids {
            guard let asset = assetsByID[id] else { continue }
            let url = asset.thumbnail.flatMap { library.absoluteURL(forRelative: $0) }
            let caption = asset.capturedAt.map { Self.yearFormatter.string(from: $0) } ?? ""
            strip.addArrangedSubview(ThumbCellView(thumbnailURL: url, caption: caption))
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        scroll.documentView = clip
        clip.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 128),
        ])
        addFullWidth(scroll)
    }

    // MARK: - Layout helpers

    private func addSectionTitle(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = PlateFont.serif(20)
        label.textColor = PlateColor.textPrimary
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = PlateColor.hairline.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let box = NSStackView(views: [label, hairline])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        addFullWidth(box)
        // Make the hairline span the box width.
        hairline.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
    }

    private func twoColumn(_ a: NSView, _ b: NSView?) -> NSView {
        let views = b == nil ? [a, NSView()] : [a, b!]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 28
        return row
    }

    /// Add a view to the main column and pin its width to the column so it spans
    /// the full content width (the stack is leading-aligned, so unconstrained
    /// children would otherwise hug their intrinsic width).
    private func addFullWidth(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    // MARK: - Formatting

    static func grouped(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Flipped container

/// Top-left origin so stacked content lays out downward and scrolls naturally.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Overview card

private final class StatCardView: NSView {
    init(value: String, label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PlateColor.surface.cgColor
        layer?.cornerRadius = 10

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = PlateFont.serif(26)
        valueLabel.textColor = PlateColor.textPrimary
        valueLabel.alignment = .left

        let nameLabel = NSTextField(labelWithString: label.uppercased())
        nameLabel.font = PlateFont.mono(10)
        nameLabel.textColor = PlateColor.textSubtle
        nameLabel.alignment = .left

        let stack = NSStackView(views: [valueLabel, nameLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 78),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Heatmap

/// One year of a GitHub-style contribution grid: 7 weekday rows × ≈53 week
/// columns, cell intensity scaled to the year's busiest day.
private final class HeatmapYearView: NSView {
    private let data: LibraryStatistics.HeatmapYear
    private let cell: CGFloat = 10
    private let gap: CGFloat = 2
    private let topInset: CGFloat = 16   // room for month labels
    private let legendHeight: CGFloat = 0

    private var colW: CGFloat { cell + gap }
    private var rowH: CGFloat { cell + gap }

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }()
    private let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Single source of truth in PlateCore so view + compute() day keys match.
        f.dateFormat = LibraryStatistics.dayKeyDateFormat
        return f
    }()

    init(data: LibraryStatistics.HeatmapYear) {
        self.data = data
        super.init(frame: .zero)
        keyFormatter.timeZone = cal.timeZone
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var jan1: Date { cal.date(from: DateComponents(year: data.year, month: 1, day: 1))! }
    private var daysInYear: Int {
        let dec31 = cal.date(from: DateComponents(year: data.year, month: 12, day: 31))!
        return (cal.dateComponents([.day], from: jan1, to: dec31).day ?? 364) + 1
    }
    private var firstWeekday: Int { cal.component(.weekday, from: jan1) - 1 }  // 0 = Sun
    private var columns: Int { (firstWeekday + daysInYear - 1) / 7 + 1 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * colW, height: topInset + 7 * rowH + legendHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let monthAttrs: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(9),
            .foregroundColor: PlateColor.textSubtle,
        ]
        for dayOffset in 0..<daysInYear {
            guard let date = cal.date(byAdding: .day, value: dayOffset, to: jan1) else { continue }
            let slot = firstWeekday + dayOffset
            let col = slot / 7
            let row = slot % 7
            let x = CGFloat(col) * colW
            let y = topInset + CGFloat(row) * rowH
            let count = data.countsByDay[keyFormatter.string(from: date)] ?? 0
            let rect = NSRect(x: x, y: y, width: cell, height: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            colorForCount(count).setFill()
            path.fill()

            // Month label at the column where each month begins.
            if cal.component(.day, from: date) == 1 {
                let m = cal.component(.month, from: date) - 1
                let name = LibraryStatistics.monthSymbols[m]
                name.draw(at: NSPoint(x: x, y: 0), withAttributes: monthAttrs)
            }
        }
    }

    private func colorForCount(_ count: Int) -> NSColor {
        guard count > 0 else { return PlateColor.raised }
        let t = data.max > 0 ? Double(count) / Double(data.max) : 0
        let level = min(4, Swift.max(1, Int((t * 4).rounded(.up))))
        let fraction: CGFloat = [0.0, 0.32, 0.55, 0.78, 1.0][level]
        return blend(PlateColor.raised, PlateColor.accent, fraction)
    }
}

// MARK: - Column chart

/// A compact bar chart for a fixed set of buckets (hours / weekdays / months).
private final class ColumnChartView: NSView {
    private let rows: [LibraryStatistics.Count]
    private let labelStride: Int
    private let labelHeight: CGFloat = 18
    private let chartHeight: CGFloat = 110

    init(rows: [LibraryStatistics.Count], labelStride: Int) {
        self.rows = rows
        self.labelStride = max(1, labelStride)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: chartHeight + labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let maxCount = rows.map(\.count).max() ?? 1
        let n = CGFloat(rows.count)
        let slotW = bounds.width / n
        let barW = min(slotW * 0.62, 22)
        let baseY = labelHeight   // origin bottom-left; labels occupy the bottom strip

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(9),
            .foregroundColor: PlateColor.textSubtle,
        ]

        for (i, row) in rows.enumerated() {
            let frac = maxCount > 0 ? CGFloat(row.count) / CGFloat(maxCount) : 0
            let h = max(frac * chartHeight, row.count > 0 ? 2 : 0)
            let cx = (CGFloat(i) + 0.5) * slotW
            let barRect = NSRect(x: cx - barW / 2, y: baseY, width: barW, height: h)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            (row.count > 0 ? PlateColor.accent : PlateColor.raised).setFill()
            path.fill()

            if i % labelStride == 0 {
                let s = row.label as NSString
                let size = s.size(withAttributes: labelAttrs)
                s.draw(at: NSPoint(x: cx - size.width / 2, y: 1), withAttributes: labelAttrs)
            }
        }
    }
}

// MARK: - Bar list

/// A titled list of labelled tallies with proportional bars (top-N).
private final class BarListView: NSView {
    let isEmptyList: Bool

    init(title: String, rows: [LibraryStatistics.Count], limit: Int) {
        let shown = Array(rows.prefix(limit))
        self.isEmptyList = shown.isEmpty
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: title.uppercased())
        header.font = PlateFont.mono(10)
        header.textColor = PlateColor.textSubtle

        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let maxCount = shown.map(\.count).max() ?? 1
        if shown.isEmpty {
            let none = NSTextField(labelWithString: "—")
            none.font = PlateFont.body(12)
            none.textColor = PlateColor.textFaint
            stack.addArrangedSubview(none)
        }
        for row in shown {
            let bar = BarRowView(label: row.label,
                                 countText: StatisticsViewController.grouped(row.count),
                                 fraction: maxCount > 0 ? CGFloat(row.count) / CGFloat(maxCount) : 0)
            stack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One row: a proportional track with the label drawn left and count right.
private final class BarRowView: NSView {
    private let label: String
    private let countText: String
    private let fraction: CGFloat

    init(label: String, countText: String, fraction: CGFloat) {
        self.label = label
        self.countText = countText
        self.fraction = max(0, min(1, fraction))
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: 2, width: bounds.width, height: bounds.height - 4)
        PlateColor.surface.setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        if fraction > 0 {
            let fillW = max(track.width * fraction, 6)
            let fill = NSRect(x: 0, y: 2, width: fillW, height: bounds.height - 4)
            blend(PlateColor.surface, PlateColor.accent, 0.5).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
        }

        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(11),
            .foregroundColor: PlateColor.textMuted,
        ]
        let countSize = (countText as NSString).size(withAttributes: countAttrs)
        let countX = bounds.width - countSize.width - 10
        (countText as NSString).draw(
            at: NSPoint(x: countX, y: (bounds.height - countSize.height) / 2),
            withAttributes: countAttrs)

        let labelPara = NSMutableParagraphStyle()
        labelPara.lineBreakMode = .byTruncatingTail
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: PlateFont.body(12),
            .foregroundColor: PlateColor.textPrimary,
            .paragraphStyle: labelPara,
        ]
        let labelHeight = (label as NSString).size(withAttributes: labelAttrs).height
        let labelRect = NSRect(x: 10, y: (bounds.height - labelHeight) / 2,
                               width: max(0, countX - 18), height: labelHeight)
        (label as NSString).draw(in: labelRect, withAttributes: labelAttrs)
    }
}

// MARK: - On This Day thumbnail

private final class ThumbCellView: NSView {
    private let imageView = NSImageView()

    init(thumbnailURL: URL?, caption: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = PlateColor.surface.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = PlateFont.mono(9)
        captionLabel.textColor = PlateColor.textSubtle
        captionLabel.alignment = .center

        let stack = NSStackView(views: [imageView, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 88),
            imageView.heightAnchor.constraint(equalToConstant: 88),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let url = thumbnailURL {
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                DispatchQueue.main.async { self.imageView.image = image }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Color blend

/// Linear sRGB blend: `t` of `b` over `a`. Used for heatmap intensity ramps
/// and bar fills so they sit on the warm-neutral palette rather than pure accent.
private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let ca = a.usingColorSpace(.sRGB) ?? a
    let cb = b.usingColorSpace(.sRGB) ?? b
    let t = max(0, min(1, t))
    return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                   green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                   blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                   alpha: 1.0)
}
