import AppKit
import FlickCore
import os

/// A gesture Flick acts on.
enum Gesture: Equatable {
    case swipe(SwipeDirection)
    case pinchIn

    var name: String {
        switch self {
        case .swipe(let direction): "swipe \(direction.rawValue)"
        case .pinchIn: "pinch in"
        }
    }
}

/// Watches the trackpad's scroll and magnify events through a session event
/// tap and reports two-finger swipes and pinches that start on a window's
/// title bar, or with ⌘ held as they start, anywhere in the window, swallowing
/// their events so the window never scrolls or zooms. A gesture reports
/// whether it was a ⌘ gesture.
///
/// While ⌘ stays held, every ⌘ gesture goes to the window the first one hit,
/// wherever the pointer is, so a window can be split, filled and sent to
/// another display in one go; releasing ⌘ lets go of it.
@MainActor
final class SwipeTap {
    var isEnabled = true

    private var swipes: SwipeRecognizer
    private var pinches = PinchRecognizer()
    private var target: AppWindow?
    private var command = false
    /// The window ⌘ gestures go to until ⌘ is released.
    private var commandTarget: AppWindow?
    private var port: CFMachPort?
    private let onProgress: (AppWindow?, Gesture?, _ command: Bool) -> Void
    private let onGesture: (AppWindow, Gesture, _ command: Bool) -> Void
    /// The gesture last reported to onProgress.
    private var reported: Gesture?
    private let logger = Logger(subsystem: "info.junz.flick", category: "gesture")

    /// Trackpad gestures reach an event tap as NSEvent's gesture type, which
    /// CGEventType has no case for; AppKit turns those whose HID type is zoom
    /// into magnify events.
    private static let gesture = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let zoomHIDType: Int64 = 8

    /// `onProgress` hears what the gesture in progress would do whenever it
    /// changes, nil once it ends or falls short; `onGesture`, each one made.
    init(threshold: Double,
         onProgress: @escaping (AppWindow?, Gesture?, _ command: Bool) -> Void,
         onGesture: @escaping (AppWindow, Gesture, _ command: Bool) -> Void) {
        swipes = SwipeRecognizer(threshold: threshold)
        self.onProgress = onProgress
        self.onGesture = onGesture
    }

    /// Starts watching; false without Accessibility permission.
    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
            | CGEventMask(1) << Self.gesture.rawValue
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
            return handleScroll(event)
        case Self.gesture:
            guard event.getIntegerValueField(Self.gestureHIDType) == Self.zoomHIDType else {
                return true
            }
            return handleMagnify(event)
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
    }

    private func handleScroll(_ event: CGEvent) -> Bool {
        // Only trackpads and Magic Mice scroll continuously.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
              let scroll = NSEvent(cgEvent: event) else { return true }
        let verdict = swipes.handle(
            phase: ScrollPhase(raw: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
            momentum: MomentumPhase(raw: event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
            deltaX: scroll.scrollingDeltaX, deltaY: scroll.scrollingDeltaY,
            inverted: scroll.isDirectionInvertedFromDevice
        ) { pickTarget(event) }
        report(swipes.pending.map(Gesture.swipe))
        switch verdict {
        case .pass: return true
        case .swallow: return false
        case .fire(let direction):
            fire(.swipe(direction))
            return false
        }
    }

    private func handleMagnify(_ event: CGEvent) -> Bool {
        guard let magnify = NSEvent(cgEvent: event), magnify.type == .magnify else { return true }
        let verdict = pinches.handle(phase: ScrollPhase(magnify.phase),
                                     magnification: magnify.magnification) { pickTarget(event) }
        report(pinches.pending ? .pinchIn : nil)
        switch verdict {
        case .pass: return true
        case .swallow: return false
        case .fire:
            fire(.pinchIn)
            return false
        }
    }

    /// Picks the window a gesture starting with `event` acts on, if any.
    private func pickTarget(_ event: CGEvent) -> Bool {
        target = nil
        // Gestures with other modifiers (zoom, horizontal scroll) keep their
        // meaning.
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

    private func report(_ pending: Gesture?) {
        guard pending != reported else { return }
        reported = pending
        // A tick under the fingers each time the gesture's action appears or
        // changes, as the preview moves.
        if pending != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let (target, command) = (target, command)
        // Outside the callback, which must return quickly.
        Task { @MainActor in self.onProgress(target, pending, command) }
    }

    private func fire(_ gesture: Gesture) {
        guard let target else { return }
        let command = command
        logger.info("""
            \(command ? "⌘ " : "", privacy: .public)\(gesture.name, privacy: .public) on \
            \(target.appName, privacy: .public)'s \(command ? "window" : "title bar", privacy: .public)
            """)
        Task { @MainActor in self.onGesture(target, gesture, command) }
    }
}

extension ScrollPhase {
    /// A magnify event's phase.
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else if phase.contains(.mayBegin) { self = .mayBegin }
        else { self = .none }
    }
}
