import Foundation

/// Static analysis of a library's assets — the data behind the Statistics view.
///
/// Pure value computation over a snapshot of `[Asset]`: no I/O, no disk reads
/// (every input is already on the row), so it's cheap to recompute and trivial
/// to unit-test. Modelled on PictorG's gallery stats: equipment breakdowns,
/// time-of-capture distributions, a GitHub-style daily heatmap, and an
/// "on this day" lookback.
public struct LibraryStatistics {

    /// A labelled tally, e.g. ("Hasselblad X2D 100C", 412). Used for every
    /// ranked breakdown (cameras, lenses, focal lengths, …).
    public struct Count: Equatable {
        public let label: String
        public let count: Int
        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    /// One year's worth of per-day tallies for the contribution heatmap.
    public struct HeatmapYear: Equatable {
        public let year: Int
        /// Photos taken on each calendar day, keyed by `yyyy-MM-dd`.
        public let countsByDay: [String: Int]
        /// The busiest single day's count — the denominator for cell intensity.
        public let max: Int
        public let total: Int
    }

    // Totals
    public let totalPhotos: Int
    public let favorites: Int
    /// Assets that carry at least one RAW companion.
    public let withRaw: Int
    /// Assets that carry GPS coordinates.
    public let withGPS: Int
    /// Assets that carry any EXIF shooting metadata (camera/lens/exposure).
    /// When this is 0 the UI nudges the user to run "Rebuild Library Data".
    public let withExif: Int
    /// Sum of pixel area across all assets, in megapixels.
    public let totalMegapixels: Double
    /// Earliest / latest capture dates among dated assets.
    public let earliestCapture: Date?
    public let latestCapture: Date?

    /// File-format breakdown, RAW companions folded in (e.g. "JPEG + RAW").
    /// Always available — derived from filenames, not EXIF.
    public let formats: [Count]

    // Equipment breakdowns (descending by count)
    public let cameras: [Count]
    public let lenses: [Count]
    public let focalLengths: [Count]
    public let apertures: [Count]
    public let shutterSpeeds: [Count]
    public let isos: [Count]

    // Time-of-capture distributions
    /// Photos per calendar year, ascending by year.
    public let byYear: [Count]
    /// Photos per month-of-year, 12 entries Jan…Dec (label = month name).
    public let byMonth: [Count]
    /// Photos per weekday, 7 entries Sun…Sat.
    public let byWeekday: [Count]
    /// Photos per hour-of-day, 24 entries 0…23.
    public let byHour: [Count]

    /// One heatmap per year that has photos, most-recent year first.
    public let heatmap: [HeatmapYear]

    /// Asset ids taken on the same month/day as `now` in prior years — the
    /// "On This Day" lookback. Newest first. The view resolves ids to thumbs.
    public let onThisDay: [UUID]

    // MARK: - Compute

    /// Build the full statistics snapshot. `now` is injectable so the
    /// "on this day" window and tests are deterministic. Uses a Gregorian
    /// calendar in the current time zone — capture dates are wall-clock local.
    public static func compute(from assets: [Asset],
                               now: Date = Date(),
                               calendar: Calendar = Calendar(identifier: .gregorian)) -> LibraryStatistics {
        var cal = calendar
        cal.timeZone = calendar.timeZone

        let total = assets.count
        let favorites = assets.lazy.filter { $0.isFavorite }.count
        let withRaw = assets.lazy.filter { !$0.raws.isEmpty }.count
        let withGPS = assets.lazy.filter { $0.latitude != nil && $0.longitude != nil }.count
        let withExif = assets.lazy.filter { hasExif($0) }.count

        var megapixels = 0.0
        for a in assets {
            if let w = a.pixelWidth, let h = a.pixelHeight {
                megapixels += Double(w) * Double(h) / 1_000_000.0
            }
        }

        let dated = assets.compactMap { $0.capturedAt }
        let earliest = dated.min()
        let latest = dated.max()

        // Format tally — always available (filename-derived), RAW folded in.
        let formats = rank(assets.map { $0.formatLabel })

        // Equipment tallies.
        let cameras = rank(assets.compactMap { $0.cameraName })
        let lenses = rank(assets.compactMap { $0.lensModel })
        let focal = rankSorted(
            assets.compactMap { $0.focalLength }.map { formatFocalLength($0) },
            by: { focalSortKey($0) })
        let apertures = rankSorted(
            assets.compactMap { $0.aperture }.map { formatAperture($0) },
            by: { apertureSortKey($0) })
        let shutters = rankSorted(
            assets.compactMap { $0.shutterSpeed }.map { formatShutter($0) },
            by: { shutterSortKey($0) })
        let isos = rankSorted(
            assets.compactMap { $0.iso }.map { "ISO \($0)" },
            by: { isoSortKey($0) })

        // Time distributions.
        var yearCounts: [Int: Int] = [:]
        var monthCounts = [Int](repeating: 0, count: 12)   // 0 = Jan
        var weekdayCounts = [Int](repeating: 0, count: 7)  // 0 = Sun
        var hourCounts = [Int](repeating: 0, count: 24)
        var dayCountsByYear: [Int: [String: Int]] = [:]

        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayKeyFormatter.calendar = cal
        dayKeyFormatter.timeZone = cal.timeZone
        dayKeyFormatter.dateFormat = dayKeyDateFormat

        for asset in assets {
            guard let date = asset.capturedAt else { continue }
            let comps = cal.dateComponents([.year, .month, .weekday, .hour], from: date)
            if let y = comps.year { yearCounts[y, default: 0] += 1 }
            if let m = comps.month, (1...12).contains(m) { monthCounts[m - 1] += 1 }
            if let wd = comps.weekday, (1...7).contains(wd) { weekdayCounts[wd - 1] += 1 }
            if let h = comps.hour, (0...23).contains(h) { hourCounts[h] += 1 }
            if let y = comps.year {
                let key = dayKeyFormatter.string(from: date)
                dayCountsByYear[y, default: [:]][key, default: 0] += 1
            }
        }

        let byYear = yearCounts.keys.sorted().map { Count(label: String($0), count: yearCounts[$0]!) }
        let byMonth = (0..<12).map { Count(label: monthName($0), count: monthCounts[$0]) }
        let byWeekday = (0..<7).map { Count(label: weekdayName($0), count: weekdayCounts[$0]) }
        let byHour = (0..<24).map { Count(label: String(format: "%02d", $0), count: hourCounts[$0]) }

        let heatmap = dayCountsByYear.keys.sorted(by: >).map { year -> HeatmapYear in
            let days = dayCountsByYear[year] ?? [:]
            return HeatmapYear(year: year,
                               countsByDay: days,
                               max: days.values.max() ?? 0,
                               total: days.values.reduce(0, +))
        }

        // On this day: same month + day-of-month as `now`, any prior year.
        let nowComps = cal.dateComponents([.month, .day], from: now)
        let onThisDay = assets
            .filter { asset in
                guard let date = asset.capturedAt else { return false }
                let c = cal.dateComponents([.month, .day], from: date)
                return c.month == nowComps.month && c.day == nowComps.day
            }
            .sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
            .map { $0.id }

        return LibraryStatistics(
            totalPhotos: total,
            favorites: favorites,
            withRaw: withRaw,
            withGPS: withGPS,
            withExif: withExif,
            totalMegapixels: megapixels,
            earliestCapture: earliest,
            latestCapture: latest,
            formats: formats,
            cameras: cameras,
            lenses: lenses,
            focalLengths: focal,
            apertures: apertures,
            shutterSpeeds: shutters,
            isos: isos,
            byYear: byYear,
            byMonth: byMonth,
            byWeekday: byWeekday,
            byHour: byHour,
            heatmap: heatmap,
            onThisDay: onThisDay)
    }

    private static func hasExif(_ a: Asset) -> Bool {
        a.cameraMake != nil || a.cameraModel != nil || a.lensModel != nil
            || a.focalLength != nil || a.aperture != nil
            || a.shutterSpeed != nil || a.iso != nil
    }

    // MARK: - Ranking

    /// Tally string values into counts, sorted by count descending then label.
    private static func rank(_ values: [String]) -> [Count] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts
            .map { Count(label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// Tally string values, but order by a natural numeric key (so focal
    /// lengths read 24 → 35 → 50, not "100" before "24"). Ties broken by count.
    private static func rankSorted(_ values: [String], by key: (String) -> Double) -> [Count] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts
            .map { Count(label: $0.key, count: $0.value) }
            .sorted { key($0.label) < key($1.label) }
    }

    // MARK: - Formatting

    public static func formatFocalLength(_ mm: Double) -> String {
        let rounded = (mm * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))mm"
        }
        return "\(rounded)mm"
    }

    public static func formatAperture(_ f: Double) -> String {
        let rounded = (f * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "f/\(Int(rounded))"
        }
        return "f/\(rounded)"
    }

    /// Seconds → photographic notation. ≥1s shown as "2s"; faster as "1/250".
    public static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 {
            let rounded = (seconds * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded))s" : "\(rounded)s"
        }
        let denom = Int((1.0 / seconds).rounded())
        return "1/\(denom)"
    }

    private static func focalSortKey(_ label: String) -> Double {
        Double(label.replacingOccurrences(of: "mm", with: "")) ?? .greatestFiniteMagnitude
    }
    private static func apertureSortKey(_ label: String) -> Double {
        Double(label.replacingOccurrences(of: "f/", with: "")) ?? .greatestFiniteMagnitude
    }
    private static func shutterSortKey(_ label: String) -> Double {
        // Sort by actual exposure duration ascending (1/8000 before 1/60 before 2s).
        if label.hasPrefix("1/"), let denom = Double(label.dropFirst(2)) {
            return 1.0 / denom
        }
        if label.hasSuffix("s"), let s = Double(label.dropLast()) {
            return s
        }
        return .greatestFiniteMagnitude
    }
    private static func isoSortKey(_ label: String) -> Double {
        Double(label.replacingOccurrences(of: "ISO ", with: "")) ?? .greatestFiniteMagnitude
    }

    /// `yyyy-MM-dd` keys for the daily heatmap. Exposed so the AppKit heatmap
    /// view formats day keys identically — a single source prevents the lookup
    /// from silently missing if one side's format string ever drifts.
    public static let dayKeyDateFormat = "yyyy-MM-dd"

    /// Short month / weekday labels, shared with the heatmap's axis labels.
    public static let monthSymbols: [String] =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let weekdaySymbols: [String] =
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func monthName(_ index: Int) -> String { monthSymbols[index] }
    private static func weekdayName(_ index: Int) -> String { weekdaySymbols[index] }
}
