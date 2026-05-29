import AppKit
import PlateCore

/// Small config panel for the read-only web gallery. Starts / stops the
/// app-wide `WebServerCoordinator`, and — while running — shows the local
/// address, the access password, and the one-liner to expose it through a
/// Cloudflare Tunnel.
///
/// Settings (port / password / LAN) are editable only while stopped; the
/// "Access" block appears only while running. The panel reflects the *globally*
/// running server, so opening it from any library window shows the same state.
final class WebServerWindowController: NSWindowController, NSWindowDelegate {

    private weak var library: PlateLibrary?
    private var libraryTitle: String

    private let contentWidth: CGFloat = 460
    private let columnWidth: CGFloat = 420

    // Status
    private let titleLabel = NSTextField(labelWithString: "Web Server")
    private let servingLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    // Settings
    private let portField = NSTextField(string: "8080")
    private let authCheckbox = NSButton(checkboxWithTitle: "Require a password", target: nil, action: nil)
    private let tokenField = NSTextField(string: "")
    private let regenerateButton = NSButton(title: "Regenerate", target: nil, action: nil)
    private let lanCheckbox = NSButton(checkboxWithTitle: "Allow other devices on this network (LAN)",
                                       target: nil, action: nil)
    private let primaryButton = NSButton(title: "Start Server", target: nil, action: nil)

    // Access (visible only while running)
    private var accessStack: NSStackView!
    private let addressValue = NSTextField(labelWithString: "")
    private var passwordRow: NSStackView!
    private let passwordValue = NSTextField(labelWithString: "")
    private let tunnelValue = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    private var mainStack: NSStackView!

    // MARK: - Init

    init(library: PlateLibrary, libraryTitle: String) {
        self.library = library
        self.libraryTitle = libraryTitle

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Web Server"
        window.backgroundColor = PlateColor.primary
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        buildUI()
        // Seed sensible defaults: password on with a fresh random token.
        authCheckbox.state = .on
        tokenField.stringValue = PlateWebServer.generateToken()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-point at the front window's library when reopened from a different
    /// library window (the server itself, if running, is unaffected).
    func updateBinding(library: PlateLibrary, libraryTitle: String) {
        self.library = library
        self.libraryTitle = libraryTitle
        refresh()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        titleLabel.font = PlateFont.serif(20, weight: .medium)
        titleLabel.textColor = PlateColor.textPrimary

        servingLabel.font = PlateFont.mono(11)
        servingLabel.textColor = PlateColor.textSubtle

        statusLabel.font = PlateFont.body(13, weight: .medium)

        // Settings rows ----------------------------------------------------
        portField.formatter = nil
        portField.alignment = .left
        portField.placeholderString = "8080"
        styleEditable(portField)
        portField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let portRow = labeledRow("Port", control: portField, trailingFill: false)

        authCheckbox.target = self
        authCheckbox.action = #selector(toggleAuth)
        styleCheckbox(authCheckbox)

        styleEditable(tokenField)
        tokenField.placeholderString = "shared secret"
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerate)
        regenerateButton.bezelStyle = .rounded
        regenerateButton.controlSize = .small
        let tokenRow = NSStackView(views: [tokenField, regenerateButton])
        tokenRow.orientation = .horizontal
        tokenRow.spacing = 8
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        lanCheckbox.target = self
        lanCheckbox.action = #selector(settingsChanged)
        styleCheckbox(lanCheckbox)

        primaryButton.target = self
        primaryButton.action = #selector(startOrStop)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.controlSize = .regular

        // Access block -----------------------------------------------------
        let accessHeader = captionLabel("ACCESS")
        configureSelectable(addressValue)
        configureSelectable(passwordValue)
        configureSelectable(tunnelValue)

        let addressRow = labeledRow("Address", control: rowWithButtons(
            addressValue,
            buttons: [makeButton("Copy", #selector(copyAddress)),
                      makeButton("Open", #selector(openInBrowser))]))
        passwordRow = labeledRow("Password", control: rowWithButtons(
            passwordValue, buttons: [makeButton("Copy", #selector(copyPassword))]))
        let tunnelRow = labeledRow("Cloudflare", control: rowWithButtons(
            tunnelValue, buttons: [makeButton("Copy", #selector(copyTunnel))]))

        noteLabel.font = PlateFont.body(11)
        noteLabel.textColor = PlateColor.textSubtle
        noteLabel.preferredMaxLayoutWidth = columnWidth

        accessStack = NSStackView(views: [
            hairline(), accessHeader, addressRow, passwordRow, tunnelRow, noteLabel,
        ])
        accessStack.orientation = .vertical
        accessStack.alignment = .leading
        accessStack.spacing = 10
        accessStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // Assemble ---------------------------------------------------------
        mainStack = NSStackView(views: [
            titleLabel, servingLabel, statusLabel,
            hairline(),
            portRow, authCheckbox, tokenRow, lanCheckbox,
            primaryButton,
            accessStack,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        // Tighten the gap between the title and its two caption lines.
        mainStack.setCustomSpacing(4, after: titleLabel)
        mainStack.setCustomSpacing(8, after: servingLabel)
        mainStack.setCustomSpacing(16, after: primaryButton)

        content.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            mainStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: columnWidth),
        ])
        // Rows that should span the full column width.
        for row in [tokenRow, primaryButton, accessStack as NSView] {
            row.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        }
    }

    // MARK: - State

    private func refresh() {
        let coordinator = WebServerCoordinator.shared
        let running = coordinator.isRunning

        if running, let server = coordinator.server {
            statusLabel.stringValue = "● Running on port \(server.port)"
            statusLabel.textColor = PlateColor.success
            servingLabel.stringValue = "SERVING · \(coordinator.boundTitle ?? libraryTitle)"
            // Mirror the live config so the fields are truthful.
            portField.stringValue = String(server.port)
            authCheckbox.state = server.requiresAuth ? .on : .off
            tokenField.stringValue = server.token ?? ""
            lanCheckbox.state = server.bindsAllInterfaces ? .on : .off

            addressValue.stringValue = server.localURL
            passwordValue.stringValue = server.token ?? ""
            passwordRow.isHidden = !server.requiresAuth
            tunnelValue.stringValue = "cloudflared tunnel --url http://localhost:\(server.port)"
            noteLabel.stringValue = server.requiresAuth
                ? "Browsers prompt for a login — leave the username blank and paste the password. Point your Cloudflare Tunnel at the address above for external access."
                : "Authentication is off — anyone who reaches this address sees every photo. Point your Cloudflare Tunnel at the address above for external access."
            primaryButton.title = "Stop Server"
            accessStack.isHidden = false
        } else {
            statusLabel.stringValue = "● Stopped"
            statusLabel.textColor = PlateColor.textSubtle
            servingLabel.stringValue = "LIBRARY · \(libraryTitle)"
            primaryButton.title = "Start Server"
            accessStack.isHidden = true
        }

        // Settings editable only while stopped.
        let editable = !running
        portField.isEnabled = editable
        authCheckbox.isEnabled = editable
        lanCheckbox.isEnabled = editable
        let authOn = authCheckbox.state == .on
        tokenField.isEnabled = editable && authOn
        regenerateButton.isEnabled = editable && authOn

        resizeToFit()
    }

    private func resizeToFit() {
        guard let window = window else { return }
        window.layoutIfNeeded()
        let height = mainStack.fittingSize.height + 40
        window.setContentSize(NSSize(width: contentWidth, height: height))
    }

    // MARK: - Actions

    @objc private func toggleAuth() { refresh() }
    @objc private func settingsChanged() { /* LAN toggle — nothing to recompute */ }

    @objc private func regenerate() {
        tokenField.stringValue = PlateWebServer.generateToken()
    }

    @objc private func startOrStop() {
        let coordinator = WebServerCoordinator.shared
        if coordinator.isRunning {
            coordinator.stop()
            refresh()
            return
        }
        guard let library = library else {
            presentSimpleAlert("No library is open to serve.")
            return
        }
        guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)), port > 0 else {
            presentSimpleAlert("Enter a valid port number (1–65535).")
            return
        }
        let token: String?
        if authCheckbox.state == .on {
            let trimmed = tokenField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                presentSimpleAlert("Set a password, or turn off “Require a password”.")
                return
            }
            token = trimmed
        } else {
            token = nil
        }
        do {
            try coordinator.start(library: library, title: libraryTitle,
                                  port: port, token: token,
                                  bindAllInterfaces: lanCheckbox.state == .on)
        } catch {
            presentServerError(error)
        }
        refresh()
    }

    @objc private func copyAddress() { copyToPasteboard(addressValue.stringValue) }
    @objc private func copyPassword() { copyToPasteboard(passwordValue.stringValue) }
    @objc private func copyTunnel() { copyToPasteboard(tunnelValue.stringValue) }

    @objc private func openInBrowser() {
        guard let server = WebServerCoordinator.shared.server,
              let url = URL(string: server.localURLWithToken) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func presentSimpleAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentServerError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t start the web server"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    // MARK: - View factory

    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = PlateFont.mono(10)
        label.textColor = PlateColor.textSubtle
        return label
    }

    private func styleEditable(_ field: NSTextField) {
        field.font = PlateFont.body(12)
        field.textColor = PlateColor.textPrimary
        field.drawsBackground = true
        field.backgroundColor = PlateColor.surface
        field.bezelStyle = .roundedBezel
    }

    private func configureSelectable(_ field: NSTextField) {
        field.font = PlateFont.mono(11)
        field.textColor = PlateColor.textPrimary
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func styleCheckbox(_ button: NSButton) {
        if let cell = button.cell as? NSButtonCell {
            cell.backgroundColor = .clear
        }
        button.contentTintColor = PlateColor.textPrimary
        // NSButton checkbox titles use the system label color; nudge readable.
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.foregroundColor: PlateColor.textPrimary, .font: PlateFont.body(13)])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    /// A label column (mono caps, fixed width) followed by a control.
    private func labeledRow(_ caption: String, control: NSView, trailingFill: Bool = true) -> NSStackView {
        let label = captionLabel(caption.uppercased())
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        if trailingFill {
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        }
        return row
    }

    /// A value view that stretches, followed by trailing buttons.
    private func rowWithButtons(_ value: NSView, buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: [value] + buttons)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = PlateColor.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        return line
    }
}
