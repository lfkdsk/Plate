import Foundation

/// A Photos-style dynamic / "smart" filter over the library's EXIF metadata.
///
/// The headline piece is `compile()` — a *pure* function that turns a set of
/// typed rules into a parameterised SQL `WHERE` predicate plus its bound values.
/// Column names are hardcoded in this file; every user-supplied value goes out
/// as a bound parameter (`?`), so the compiled SQL is injection-safe by
/// construction. The predicate is executed by `AssetStore.assets(matching:)`.
///
/// Being pure + value-typed, the whole compiler is unit-testable with no DB:
/// assert that a rule set produces the expected SQL string and bindings.
public struct SmartFilter: Equatable {

    /// How the rules combine. `.all` → AND (every rule must match), `.any` → OR.
    public enum Match: Equatable {
        case all
        case any
    }

    public var match: Match
    public var rules: [Rule]

    public init(match: Match = .all, rules: [Rule] = []) {
        self.match = match
        self.rules = rules
    }

    /// True when there's nothing to filter — callers fall back to the plain
    /// "all assets" query so an empty filter is indistinguishable from no filter.
    public var isEmpty: Bool { rules.isEmpty }

    // MARK: - Rule model

    /// A comparison against a numeric EXIF field. NULL fields never match a
    /// numeric rule (SQLite NULL comparisons are false), so "ISO ≥ 400" excludes
    /// photos with unknown ISO — the intuitive behaviour.
    public enum NumberMatch: Equatable {
        case atLeast(Double)
        case atMost(Double)
        case between(Double, Double)
        case equalTo(Double)
    }

    /// A comparison against a text EXIF field (camera / lens).
    public enum TextMatch: Equatable {
        case `is`(String)
        case isNot(String)
        case contains(String)
    }

    /// A comparison against capture date.
    public enum DateMatch: Equatable {
        case year(Int)
        case after(Date)
        case before(Date)
        case between(Date, Date)
    }

    /// One filter rule. Typed cases keep field + value combinations valid by
    /// construction (no "ISO contains 'Canon'" nonsense), and each maps to a
    /// single SQL fragment in `compile()`.
    public enum Rule: Equatable {
        case camera(TextMatch)
        case lens(TextMatch)
        case iso(NumberMatch)
        case aperture(NumberMatch)
        case focalLength(NumberMatch)
        case shutterSpeed(NumberMatch)
        case captured(DateMatch)
        case isFavorite(Bool)
        case hasRaw(Bool)
        case hasGPS(Bool)
    }

    // MARK: - Compiled output

    /// A bound SQL value. Mirrors the column affinities used by AssetStore so
    /// the store can bind each without re-inspecting types.
    public enum Binding: Equatable {
        case text(String)
        case int(Int64)
        case double(Double)
    }

    /// The result of compiling a filter: a `WHERE`-ready predicate (without the
    /// `WHERE` keyword) and the values to bind, in left-to-right `?` order.
    /// `whereSQL` is empty when the filter is empty.
    public struct Compiled: Equatable {
        public let whereSQL: String
        public let bindings: [Binding]
        public init(whereSQL: String, bindings: [Binding]) {
            self.whereSQL = whereSQL
            self.bindings = bindings
        }
        public var isEmpty: Bool { whereSQL.isEmpty }
    }

    // MARK: - Compile

    /// Compile the rules into a parameterised predicate. Each rule yields one
    /// parenthesised fragment; fragments join with AND (`.all`) or OR (`.any`).
    /// Returns an empty `Compiled` when there are no rules.
    ///
    /// `calendar` is injectable so `.year` ranges and tests are deterministic.
    public func compile(calendar: Calendar = Calendar(identifier: .gregorian)) -> Compiled {
        guard !rules.isEmpty else { return Compiled(whereSQL: "", bindings: []) }

        var fragments: [String] = []
        var bindings: [Binding] = []
        for rule in rules {
            let (sql, binds) = Self.fragment(for: rule, calendar: calendar)
            fragments.append(sql)
            bindings.append(contentsOf: binds)
        }
        let joiner = (match == .all) ? " AND " : " OR "
        // Wrap each fragment in parens so AND/OR precedence is unambiguous, and
        // wrap the whole thing so callers can safely AND it with their own
        // clauses (e.g. deleted_at IS NULL).
        let combined = "(" + fragments.map { "(\($0))" }.joined(separator: joiner) + ")"
        return Compiled(whereSQL: combined, bindings: bindings)
    }

    // MARK: - Per-rule SQL

    private static func fragment(for rule: Rule, calendar: Calendar) -> (String, [Binding]) {
        switch rule {
        case .camera(let m):       return text(column: "camera_model", m)
        case .lens(let m):         return text(column: "lens_model", m)
        case .iso(let m):          return number(column: "iso", m)
        case .aperture(let m):     return number(column: "aperture", m)
        case .focalLength(let m):  return number(column: "focal_length", m)
        case .shutterSpeed(let m): return number(column: "shutter_speed", m)
        case .captured(let m):     return date(m, calendar: calendar)
        case .isFavorite(let on):  return ("is_favorite = \(on ? 1 : 0)", [])
        case .hasRaw(let on):
            // No inner parens — compile() wraps every fragment in exactly one
            // paren pair, so the OR here is already grouped within its rule.
            return on
                ? ("raws_json IS NOT NULL AND raws_json <> '[]'", [])
                : ("raws_json IS NULL OR raws_json = '[]'", [])
        case .hasGPS(let on):
            return on
                ? ("latitude IS NOT NULL AND longitude IS NOT NULL", [])
                : ("latitude IS NULL OR longitude IS NULL", [])
        }
    }

    private static func text(column: String, _ m: TextMatch) -> (String, [Binding]) {
        switch m {
        case .is(let v):
            return ("\(column) = ? COLLATE NOCASE", [.text(v)])
        case .isNot(let v):
            // Unknown-value rows (NULL) are "not X", so include them. No inner
            // parens — compile() wraps each fragment exactly once.
            return ("\(column) IS NULL OR \(column) <> ? COLLATE NOCASE", [.text(v)])
        case .contains(let v):
            return ("\(column) LIKE ? ESCAPE '\\' COLLATE NOCASE", [.text("%\(escapeLike(v))%")])
        }
    }

    private static func number(column: String, _ m: NumberMatch) -> (String, [Binding]) {
        switch m {
        case .atLeast(let v):       return ("\(column) >= ?", [.double(v)])
        case .atMost(let v):        return ("\(column) <= ?", [.double(v)])
        case .equalTo(let v):       return ("\(column) = ?", [.double(v)])
        case .between(let lo, let hi):
            let (a, b) = lo <= hi ? (lo, hi) : (hi, lo)
            return ("\(column) BETWEEN ? AND ?", [.double(a), .double(b)])
        }
    }

    private static func date(_ m: DateMatch, calendar: Calendar) -> (String, [Binding]) {
        // captured_at is REAL epoch seconds (timeIntervalSince1970).
        switch m {
        case .year(let y):
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))
                ?? Date(timeIntervalSince1970: 0)
            let end = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1))
                ?? Date(timeIntervalSince1970: 0)
            return ("captured_at >= ? AND captured_at < ?",
                    [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)])
        case .after(let d):
            return ("captured_at >= ?", [.double(d.timeIntervalSince1970)])
        case .before(let d):
            return ("captured_at < ?", [.double(d.timeIntervalSince1970)])
        case .between(let lo, let hi):
            let (a, b) = lo <= hi ? (lo, hi) : (hi, lo)
            return ("captured_at >= ? AND captured_at <= ?",
                    [.double(a.timeIntervalSince1970), .double(b.timeIntervalSince1970)])
        }
    }

    /// Escape LIKE wildcards in user input so a literal "%" or "_" in a lens
    /// name doesn't act as a wildcard. Paired with `ESCAPE '\'` in the SQL.
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
