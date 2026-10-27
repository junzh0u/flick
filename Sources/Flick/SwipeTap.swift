import AppKit
import FlickCore
import os

/// Watches the trackpad's scroll events through a session event tap and
/// reports two-finger swipes that start on a window's title bar, swallowing
/// their events so the window never scrolls. A swipe reports whether ⌘ was
/// held as the fingers lifted.
@MainActor
final class SwipeTap {
    var isEnabled = true

    private var recognizer: SwipeRecognizer
    private var target: AppWindow?
    private var port: CFMachPort?
    private let onSwipe: (AppWindow, SwipeDirection, _ command: Bool) -> Void
    private let logger = Logger(subsystem: "info.junz.flick", category: "gesture")

    init(threshold: Double, onSwipe: @escaping (AppWindow, SwipeDirection, _ command: Bool) -> Void) {
        recognizer = SwipeRecognizer(threshold: threshold)
        self.onSwipe = onSwipe
    }

    /// Starts watching; false without Accessibility permission.
    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
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
            // their meaning; ⌘ picks the display moves.
            guard isEnabled, event.flags.isDisjoint(with: [
                .maskAlternate, .maskControl, .maskShift,
            ]) else { return false }
            target = AppWindow.titleBar(at: event.location)
            return target != nil
        }

        switch verdict {
        case .pass:
            return true
        case .swallow:
            return false
        case .fire(let direction):
            if let target {
                let command = event.flags.contains(.maskCommand)
                logger.info("""
                    swipe \(command ? "⌘" : "", privacy: .public)\(direction.rawValue, privacy: .public) \
                    on \(target.appName, privacy: .public)'s title bar \
                    (natural scrolling \(scroll.isDirectionInvertedFromDevice, privacy: .public))
                    """)
                // Outside the callback, which must return quickly.
                Task { @MainActor in self.onSwipe(target, direction, command) }
            }
            return false
        }
    }
}
