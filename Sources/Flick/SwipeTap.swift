import AppKit
import FlickCore
import os

/// Watches the trackpad's scroll events through a session event tap and
/// reports two-finger swipes that start on a window's title bar, or with ⌘
/// held as they start, anywhere in the window, swallowing their events so the
/// window never scrolls. A swipe reports whether it was a ⌘ swipe.
///
/// While ⌘ stays held, every ⌘ swipe goes to the window the first one hit,
/// wherever the pointer is, so a window can be split, filled and sent to
/// another display in one go; releasing ⌘ lets go of it.
@MainActor
final class SwipeTap {
    var isEnabled = true

    private var recognizer: SwipeRecognizer
    private var target: AppWindow?
    private var command = false
    /// The window ⌘ swipes go to until ⌘ is released.
    private var commandTarget: AppWindow?
    private var port: CFMachPort?
    private let onProgress: (AppWindow?, SwipeDirection?, _ command: Bool) -> Void
    private let onSwipe: (AppWindow, SwipeDirection, _ command: Bool) -> Void
    /// The direction last reported to onProgress.
    private var reported: SwipeDirection?
    private let logger = Logger(subsystem: "info.junz.flick", category: "gesture")

    /// `onProgress` hears the way the swipe in progress would go whenever it
    /// changes, nil once it ends or falls short; `onSwipe`, each swipe made.
    init(threshold: Double,
         onProgress: @escaping (AppWindow?, SwipeDirection?, _ command: Bool) -> Void,
         onSwipe: @escaping (AppWindow, SwipeDirection, _ command: Bool) -> Void) {
        recognizer = SwipeRecognizer(threshold: threshold)
        self.onProgress = onProgress
        self.onSwipe = onSwipe
    }

    /// Starts watching; false without Accessibility permission.
    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // The tap's source is on the main run loop.
                let tap = Unmanaged<SwipeTap>.fromOpaque(refcon!).takeUnretainedValue()
                let deliver = MainActor.assumeIsolated { tap.handle(type, event) }
                return deliver ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0),
                           .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Whether the event should be delivered.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .scrollWheel:
            break
        case .flagsChanged:
            if !event.flags.contains(.maskCommand) { commandTarget = nil }
            return true
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            logger.notice("event tap was disabled; re-enabling")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        default:
            return true
        }
        // Only trackpads and Magic Mice scroll continuously.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
              let scroll = NSEvent(cgEvent: event) else { return true }

        let verdict = recognizer.handle(
            phase: ScrollPhase(raw: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
            momentum: MomentumPhase(raw: event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
            deltaX: scroll.scrollingDeltaX, deltaY: scroll.scrollingDeltaY,
            inverted: scroll.isDirectionInvertedFromDevice
        ) {
            target = nil
            // Scrolls with other modifiers (zoom, horizontal scroll) keep
            // their meaning.
            guard isEnabled, event.flags.isDisjoint(with: [
                .maskAlternate, .maskControl, .maskShift,
            ]) else { return false }
            command = event.flags.contains(.maskCommand)
            if !command {
                // ⌘ was released while the tap couldn't see it.
                commandTarget = nil
                target = AppWindow.titleBar(at: event.location)
            } else if let held = commandTarget, held.frame != nil {
                target = held
            } else {
                target = AppWindow.window(at: event.location)
                commandTarget = target
            }
            return target != nil
        }

        let pending = recognizer.pending
        if pending != reported {
            reported = pending
            let (target, command) = (target, command)
            // Outside the callback, which must return quickly.
            Task { @MainActor in self.onProgress(target, pending, command) }
        }

        switch verdict {
        case .pass:
            return true
        case .swallow:
            return false
        case .fire(let direction):
            if let target {
                let command = command
                logger.info("""
                    swipe \(command ? "⌘" : "", privacy: .public)\(direction.rawValue, privacy: .public) \
                    on \(target.appName, privacy: .public)'s \(command ? "window" : "title bar", privacy: .public) \
                    (natural scrolling \(scroll.isDirectionInvertedFromDevice, privacy: .public))
                    """)
                // Outside the callback, which must return quickly.
                Task { @MainActor in self.onSwipe(target, direction, command) }
            }
            return false
        }
    }
}
