import AppKit
import PlateCore

/// App-side glue for the in-app update check. Owns the GitHub coordinates, the
/// running version, the "once per day" throttle for the silent launch check,
/// and the alerts. The actual fetch + version comparison lives in PlateCore's
/// `UpdateChecker` (pure + tested); this type only decides *when* to check and
/// *how* to present the result.
enum UpdateCoordinator {

    /// Repo to check. Matches the GitHub remote (git@github.com:lfkdsk/HSMA).
    private static let owner = "lfkdsk"
    private static let repo = "HSMA"

    /// UserDefaults key for the last silent-check date (day granularity).
    private static let lastCheckKey = "PlateLastUpdateCheck"

    /// Running app version from Info.plist (CFBundleShortVersionString).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - Silent launch check (throttled)

    /// Called once on launch. Checks at most once per calendar day; on finding a
    /// newer release it shows the same prompt as the manual check. Silent about
    /// "up to date" and about network errors — a launch check must never nag.
    static func checkOnLaunchIfDue() {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           Calendar.current.isDate(last, inSameDayAs: today) {
            return   // already checked today
        }
        defaults.set(today, forKey: lastCheckKey)

        UpdateChecker.check(owner: owner, repo: repo, currentVersion: currentVersion) { result in
            guard case .success(let release?) = result else { return }   // silent unless newer
            DispatchQueue.main.async { presentUpdateAvailable(release) }
        }
    }

    // MARK: - Manual check (App ▸ Check for Updates…)

    /// Called from the menu. Unlike the silent check, this always reports back:
    /// a newer release, "you're up to date", or an error.
    static func checkManually() {
        UpdateChecker.check(owner: owner, repo: repo, currentVersion: currentVersion) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let release?):
                    presentUpdateAvailable(release)
                case .success(nil):
                    presentUpToDate()
                case .failure(let error):
                    presentError(error)
                }
            }
        }
    }

    // MARK: - Alerts

    private static func presentUpdateAvailable(_ release: UpdateChecker.Release) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A new version of Plate is available"
        var info = "Plate \(release.tagName) is available — you have \(currentVersion)."
        if !release.notes.isEmpty {
            // Show the first few lines of the notes, trimmed.
            let preview = release.notes
                .split(separator: "\n").prefix(8).joined(separator: "\n")
            info += "\n\n\(preview)"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date"
        alert.informativeText = "Plate \(currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
