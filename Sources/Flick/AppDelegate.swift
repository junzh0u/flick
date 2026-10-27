import AppKit
import Combine
import FlickCore
import os
import ServiceManagement
import SwiftUI

/// What a gesture does, on a title bar or with ⌘ held anywhere in a window:
/// swiping ↑ fills, ← → split and ↓ moves the window to the next display;
/// pinching in minimizes. With ⌘⇧, ← → split the area with the window behind.
enum Plan {
    case arrange(Action)
    /// Split the area with the window behind, taking this side.
    case pair(Action)
    case minimize
    case nextDisplay

    init(_ gesture: Gesture, shift: Bool) {
        switch gesture {
        case .swipe(.up): self = .arrange(.fill)
        case .swipe(.left): self = shift ? .pair(.left) : .arrange(.left)
        case .swipe(.right): self = shift ? .pair(.right) : .arrange(.right)
        case .swipe(.down): self = .nextDisplay
        case .pinchIn: self = .minimize
        }
    }

    var name: String {
        switch self {
        case .arrange(let action): action.rawValue
        case .pair(let side): "pair \(side.rawValue)"
        case .minimize: "minimize"
        case .nextDisplay: "next display"
        }
    }

    /// The SF Symbol its preview shows, for a split of `fraction`.
    func symbol(fraction: Double) -> String {
        switch self {
        case .pair(let side): Plan.arrange(side).symbol(fraction: fraction)
        case .arrange(.fill): "rectangle.inset.filled"
        case .arrange(.left) where fraction < 0.5: "rectangle.leftthird.inset.filled"
        case .arrange(.right) where fraction < 0.5: "rectangle.rightthird.inset.filled"
        case .arrange(.left): "rectangle.lefthalf.inset.filled"
        case .arrange(.right): "rectangle.righthalf.inset.filled"
        case .arrange(.top): "rectangle.tophalf.inset.filled"
        case .arrange(.bottom): "rectangle.bottomhalf.inset.filled"
        case .minimize: "minus"
        case .nextDisplay: "rectangle.on.rectangle"
        }
    }
}

/// The settings that stay with this Mac rather than in the synced file.
enum Defaults {
    /// Whether Flick is on, a quick pause from the menu.
    static let enabled = "Enabled"

    static func register() {
        UserDefaults.standard.register(defaults: [enabled: true])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(subsystem: "info.junz.flick", category: "app")
    private let worker = DispatchQueue(label: "info.junz.flick.arrange", qos: .userInteractive)
    private var statusItem: NSStatusItem?
    private var tap: SwipeTap?
    private var permissionTimer: Timer?
    private let preview = PreviewOverlay()
    /// The second panel, for the other window of a pair.
    private let companionPreview = PreviewOverlay()
    private var splits = SplitCycle()
    private let store = SettingsStore()
    private var settingsWatch: AnyCancellable?
    private var settingsWindow: NSWindow?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled),
                                         keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Show Previews", action: #selector(togglePreviews),
                                         keyEquivalent: "")
    private let pointerItem = NSMenuItem(title: "Keep Pointer on Title Bar",
                                         action: #selector(togglePointer), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin),
                                       keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                          keyEquivalent: ",")

    private var settings: FlickSettings { store.settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        setUpMenu()
        settingsWatch = store.$settings.sink { [weak self] settings in
            MainActor.assumeIsolated { self?.tap?.apply(settings) }
        }
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
        previewItem.target = self
        pointerItem.target = self
        loginItem.target = self
        settingsItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(previewItem)
        menu.addItem(pointerItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit Flick", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        enabledItem.state = UserDefaults.standard.bool(forKey: Defaults.enabled) ? .on : .off
        previewItem.state = settings.showPreviews ? .on : .off
        pointerItem.state = settings.keepPointerOnTitleBar ? .on : .off
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
        let tap = SwipeTap(onProgress: { [weak self] in self?.preview($0, $1, $2) },
                           onGesture: { [weak self] in self?.perform($0, $1, $2) })
        tap.apply(settings)
        tap.isEnabled = UserDefaults.standard.bool(forKey: Defaults.enabled)
        if tap.start() {
            self.tap = tap
            statusLine.title = "↑ fill · ← → split · ⇧← ⇧→ pair · ↓ next display · pinch minimize"
            logger.notice("watching the trackpad")
        } else {
            statusLine.title = "Couldn't watch the trackpad"
            logger.error("creating the event tap failed")
        }
    }

    /// Shows where the gesture in progress would put `target`, or hides the
    /// preview when `gesture` is nil.
    private func preview(_ target: AppWindow?, _ gesture: Gesture?, _ modifiers: Modifiers) {
        companionPreview.hide()
        guard let target, let gesture,
              settings.showPreviews,
              let window = target.frame else {
            preview.hide()
            return
        }
        let hold = modifiers.hold
        let plan = Plan(gesture, shift: modifiers.shift)
        let stages = stageManagerEnabled() ? StageWatcher.shared.frames(waitingUpTo: 0) : nil
        let frame: CGRect
        var fraction = 0.5
        do {
            switch plan {
            case .arrange(let action):
                fraction = splits.fraction(action, hold: hold)
                frame = try actionFrame(action, fraction: fraction, window: window,
                                        displays: currentDisplays(), stages: stages)
            case .pair(let side):
                fraction = splits.fraction(side, paired: true, hold: hold)
                let area = try placement(for: side, window: window, displays: currentDisplays(),
                                         stages: stages).stage
                guard target.companion(in: area) != nil else {
                    preview.hide()
                    return
                }
                let (mine, theirs) = pairFrames(side, fraction: fraction, in: area)
                frame = mine
                companionPreview.show(theirs, symbol: Plan.arrange(side.opposite)
                    .symbol(fraction: 1 - fraction))
            case .nextDisplay:
                frame = try displayMove(window: window, .next, displays: currentDisplays(),
                                        stages: stages).target
            case .minimize:
                frame = CGRect(x: window.midX - 70, y: window.midY - 70, width: 140, height: 140)
            }
        } catch {
            preview.hide()
            return
        }
        preview.show(frame, symbol: plan.symbol(fraction: fraction))
    }

    private func perform(_ target: AppWindow, _ gesture: Gesture, _ modifiers: Modifiers) {
        let hold = modifiers.hold
        let command = hold != nil
        let plan = Plan(gesture, shift: modifiers.shift)
        var label = plan.name
        let decide: () throws(ArrangeError) -> Arrangement
        switch plan {
        case .nextDisplay:
            splits.performed(nil, hold: hold)
            decide = { () throws(ArrangeError) in try arrangement(.next, for: target, stageWait: 0.1) }
        case .minimize:
            splits.performed(nil, hold: hold)
            decide = { minimizing(target) }
        case .arrange(let action):
            let fraction = splits.fraction(action, hold: hold)
            splits.performed(action, hold: hold)
            if fraction != 0.5 && action != .fill { label += fraction > 0.5 ? " ⅔" : " ⅓" }
            decide = { () throws(ArrangeError) in
                try arrangement(action, fraction: fraction, for: target, stageWait: 0.1)
            }
        case .pair(let side):
            let fraction = splits.fraction(side, paired: true, hold: hold)
            splits.performed(side, paired: true, hold: hold)
            if fraction != 0.5 { label += fraction > 0.5 ? " ⅔" : " ⅓" }
            decide = { () throws(ArrangeError) in
                try pairArrangement(side, fraction: fraction, for: target, stageWait: 0.1)
            }
        }
        let name = label
        // Window-menu commands act on the frontmost app's main window, and a
        // window moved to another display should come along to the front;
        // minimizing needs no focus, and raising first would only flash it.
        let staysOnScreen: Bool
        if case .minimize = plan { staysOnScreen = false } else { staysOnScreen = true }
        if staysOnScreen { target.focus() }
        let logger = logger
        do {
            let arrangement = try decide()
            logger.info("\(name, privacy: .public): \(arrangement.summary, privacy: .public)")
            let duration = settings.animationDuration
            // A ⌘ swipe works anywhere in the window, so the pointer stays put.
            let keepPointer = staysOnScreen && !command
                && settings.keepPointerOnTitleBar
            worker.async {
                do {
                    try FlickCore.perform(arrangement, duration: duration)
                    if keepPointer { keepPointerOnTitleBar(of: target) }
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

    @objc private func togglePreviews() {
        store.update { $0.showPreviews.toggle() }
    }

    @objc private func togglePointer() {
        store.update { $0.keepPointerOnTitleBar.toggle() }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(store: store)))
            window.title = "Flick Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // A menu-bar app is never active on its own.
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
