import AppKit

// Keep main.swift minimal — all the "set this before NSApp runs" hooks happen
// safely inside AppDelegate.applicationWillFinishLaunching, after NSApp is
// fully bootstrapped. Doing them at top-level was crashing on launch.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
