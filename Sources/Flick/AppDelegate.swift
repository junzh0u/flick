import AppKit
import FlickCore
import os
import ServiceManagement

/// What a gesture does, on a title bar or with ⌘ held anywhere in a window:
/// swiping ↑ fills, ← → split and ↓ moves the window to the next display;
/// pinching in minimizes.
enum Plan {
    case arrange(Action)
    case minimize
    case nextDisplay

    init(_ gesture: Gesture) {
        switch gesture {
        case .swipe(.up): self = .arrange(.fill)
        case .swipe(.left): self = .arrange(.left)
        case .swipe(.right): self = .arrange(.right)
        case .swipe(.down): self = .nextDisplay
        case .pinchIn: self = .minimize
        }
    }

    var name: String {
        switch self {
        case .arrange(let action): action.rawValue
        case .minimize: "minimize"
        case .nextDisplay: "next display"
        }
    }

    /// The SF Symbol its preview shows, for a split of `fraction`.
    func symbol(fraction: Double) -> String {
        switch self {
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

enum Defaults {
    static let enabled = "Enabled"
    static let threshold = "SwipeThreshold"
    static let duration = "AnimationDuration"
    static let pointerOnTitleBar = "KeepPointerOnTitleBar"
    static let previews = "ShowPreviews"

    static func register() {
        UserDefaults.standard.register(defaults: [
            enabled: true, threshold: 50.0, duration: 0.2, pointerOnTitleBar: true, previews: true,
        ])
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
    private var splits = SplitCycle()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled),
                                         keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Show Previews", action: #selector(togglePreviews),
                                         keyEquivalent: "")
    private let pointerItem = NSMenuItem(title: "Keep Pointer on Title Bar",
                                         action: #selector(togglePointer), keyEquivalent: "")
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
        previewItem.target = self
        pointerItem.target = self
        loginItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(previewItem)
        menu.addItem(pointerItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Flick", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        enabledItem.state = UserDefaults.standard.bool(forKey: Defaults.enabled) ? .on : .off
        previewItem.state = UserDefaults.standard.bool(forKey: Defaults.previews) ? .on : .off
        pointerItem.state = UserDefaults.standard.bool(forKey: Defaults.pointerOnTitleBar) ? .on : .off
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
        let tap = SwipeTap(threshold: defaults.double(forKey: Defaults.threshold),
                           onProgress: { [weak self] in self?.preview($0, $1, hold: $2) },
                           onGesture: { [weak self] in self?.perform($0, $1, hold: $2) })
        tap.isEnabled = defaults.bool(forKey: Defaults.enabled)
        if tap.start() {
            self.tap = tap
            statusLine.title = "↑ fill · ← → split · ↓ next display · pinch minimize"
            logger.notice("watching the trackpad")
        } else {
            statusLine.title = "Couldn't watch the trackpad"
            logger.error("creating the event tap failed")
        }
    }

    /// Shows where the gesture in progress would put `target`, or hides the
    /// preview when `gesture` is nil.
    private func preview(_ target: AppWindow?, _ gesture: Gesture?, hold: Int?) {
        guard let target, let gesture,
              UserDefaults.standard.bool(forKey: Defaults.previews),
              let window = target.frame else {
            preview.hide()
            return
        }
        let plan = Plan(gesture)
        let stages = stageManagerEnabled() ? StageWatcher.shared.frames(waitingUpTo: 0) : nil
        let frame: CGRect
        var fraction = 0.5
        do {
            switch plan {
            case .arrange(let action):
                fraction = splits.fraction(action, hold: hold)
                frame = try actionFrame(action, fraction: fraction, window: window,
                                        displays: currentDisplays(), stages: stages)
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

    private func perform(_ target: AppWindow, _ gesture: Gesture, hold: Int?) {
        let command = hold != nil
        let plan = Plan(gesture)
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
            let duration = UserDefaults.standard.double(forKey: Defaults.duration)
            // A ⌘ swipe works anywhere in the window, so the pointer stays put.
            let keepPointer = staysOnScreen && !command
                && UserDefaults.standard.bool(forKey: Defaults.pointerOnTitleBar)
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
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Defaults.previews), forKey: Defaults.previews)
    }

    @objc private func togglePointer() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Defaults.pointerOnTitleBar), forKey: Defaults.pointerOnTitleBar)
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
