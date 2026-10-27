import AppKit
import FlickCore
import os
import ServiceManagement

/// Which arrangement each swipe performs, and with ⌘ held, which way it moves
/// the window between displays; a swipe without one does nothing.
let actions: [SwipeDirection: Action] = [.up: .fill, .left: .left, .right: .right]
let displaySteps: [SwipeDirection: DisplayStep] = [.left: .previous, .right: .next]

enum Defaults {
    static let enabled = "Enabled"
    static let threshold = "SwipeThreshold"
    static let duration = "AnimationDuration"

    static func register() {
        UserDefaults.standard.register(defaults: [enabled: true, threshold: 50.0, duration: 0.2])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(subsystem: "info.junz.flick", category: "app")
    private let worker = DispatchQueue(label: "info.junz.flick.arrange", qos: .userInteractive)
    private var statusItem: NSStatusItem?
    private var tap: SwipeTap?
    private var permissionTimer: Timer?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled),
                                         keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin),
                                       keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        setUpMenu()
        // Connect now, so the first swipe already has the stages.
        _ = StageWatcher.shared
        startWhenTrusted()
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                     accessibilityDescription: "Flick")
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        enabledItem.target = self
        loginItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Flick", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        enabledItem.state = UserDefaults.standard.bool(forKey: Defaults.enabled) ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Watching

    private func startWhenTrusted() {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            startTap()
            return
        }
        statusLine.title = "Waiting for Accessibility permission…"
        logger.notice("waiting for Accessibility permission")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.startTap()
            }
        }
    }

    private func startTap() {
        let defaults = UserDefaults.standard
        let tap = SwipeTap(threshold: defaults.double(forKey: Defaults.threshold)) { [weak self] in
            self?.swiped($0, $1, command: $2)
        }
        tap.isEnabled = defaults.bool(forKey: Defaults.enabled)
        if tap.start() {
            self.tap = tap
            statusLine.title = "Swipe on a title bar: ↑ fill, ← → split, ⌘← ⌘→ display"
            logger.notice("watching the trackpad")
        } else {
            statusLine.title = "Couldn't watch the trackpad"
            logger.error("creating the event tap failed")
        }
    }

    private func swiped(_ target: AppWindow, _ direction: SwipeDirection, command: Bool) {
        let name: String
        let decide: () throws(ArrangeError) -> Arrangement
        if command {
            guard let step = displaySteps[direction] else { return }
            name = "\(step.rawValue) display"
            decide = { () throws(ArrangeError) in try arrangement(step, for: target) }
        } else {
            guard let action = actions[direction] else { return }
            name = action.rawValue
            decide = { () throws(ArrangeError) in try arrangement(action, for: target, stageWait: 0.1) }
        }
        target.focus()
        let logger = logger
        do {
            let arrangement = try decide()
            logger.info("\(name, privacy: .public): \(arrangement.summary, privacy: .public)")
            let duration = UserDefaults.standard.double(forKey: Defaults.duration)
            worker.async {
                do {
                    try FlickCore.perform(arrangement, duration: duration)
                } catch {
                    logger.error("\(name, privacy: .public): \(String(describing: error), privacy: .public)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        } catch {
            logger.error("\(name, privacy: .public): \(error.description, privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Menu actions

    @objc private func toggleEnabled() {
        let enabled = !UserDefaults.standard.bool(forKey: Defaults.enabled)
        UserDefaults.standard.set(enabled, forKey: Defaults.enabled)
        tap?.isEnabled = enabled
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("launch at login: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}
