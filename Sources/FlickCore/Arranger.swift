import ApplicationServices
import Darwin
import Foundation
import QuartzCore

public struct ArrangeError: Error, CustomStringConvertible {
    public let description: String
}

/// A decided arrangement, ready to carry out off the main thread.
public struct Arrangement: @unchecked Sendable {
    enum Step {
        case press(AXUIElement)
        /// Moves the window, easing it there within a display, or jumping it
        /// to another one when `crossesDisplays`.
        case move(app: AXUIElement, window: AXUIElement, from: CGRect, to: CGRect, fps: Int,
                  crossesDisplays: Bool)
        /// Moves several windows within a display, easing them together.
        case moveTogether([Move], fps: Int)
        case minimize(AXUIElement)
    }

    struct Move {
        let app: AXUIElement
        let window: AXUIElement
        let from: CGRect
        let to: CGRect
    }

    let step: Step
    /// What it will do, e.g. "Safari: Window → Fill" or
    /// "Safari: stage 218 33 1510 1084, frame 218 33 755 1084".
    public let summary: String
}

/// Decides how to carry out `action` on `target`, giving it `fraction` of the
/// area on that side. With Stage Manager off, fills and halves are macOS's own
/// Window-menu commands; thirds, which macOS has none for, take that part of
/// the display's visible frame. With it on, Fill would cover the strip of
/// recent apps, so the window instead takes the matching part of its display's
/// stage — the area beside the strip where macOS itself places new windows.
@MainActor
public func arrangement(_ action: Action, fraction: Double = 0.5, for target: AppWindow,
                        stageWait: TimeInterval) throws(ArrangeError) -> Arrangement {
    let name = target.appName
    let stageManager = stageManagerEnabled()
    if !stageManager && (action == .fill || fraction == 0.5) {
        let path = (["Window"] + action.menuPath).joined(separator: " → ")
        guard let item = windowMenuItem(target.app, path: action.menuPath) else {
            throw ArrangeError(description: "\(name) has no \(path)")
        }
        return Arrangement(step: .press(item), summary: "\(name): \(path)")
    }

    guard let start = target.frame else {
        throw ArrangeError(description: "\(name)'s window has no frame")
    }
    let p: Placement
    do {
        p = try placement(for: action, fraction: fraction, window: start,
                          displays: currentDisplays(),
                          stages: stageManager ? StageWatcher.shared.frames(waitingUpTo: stageWait) : nil)
    } catch {
        throw ArrangeError(description: error.description)
    }
    return Arrangement(
        step: .move(app: target.app, window: target.window, from: start, to: p.target,
                    fps: p.display.fps, crossesDisplays: false),
        summary: "\(name): \(stageManager ? "stage" : "visible") \(describe(p.stage)), "
            + "frame \(describe(p.target))")
}

/// Decides how to move `target` to the previous or next display, keeping its
/// position and size relative to each display's usable area — the stage with
/// Stage Manager on, else the visible frame — so a filled window stays filled
/// and a half stays that half. It jumps there, as Window → Move to does.
@MainActor
public func arrangement(_ step: DisplayStep, for target: AppWindow,
                        stageWait: TimeInterval) throws(ArrangeError) -> Arrangement {
    guard let start = target.frame else {
        throw ArrangeError(description: "\(target.appName)'s window has no frame")
    }
    let stages = stageManagerEnabled() ? StageWatcher.shared.frames(waitingUpTo: stageWait) : nil
    let p: Placement
    do {
        p = try displayMove(window: start, step, displays: currentDisplays(), stages: stages)
    } catch {
        throw ArrangeError(description: error.description)
    }
    return Arrangement(
        step: .move(app: target.app, window: target.window, from: start, to: p.target,
                    fps: p.display.fps, crossesDisplays: true),
        summary: "\(target.appName): \(p.display.name) \(describe(p.stage)), "
            + "frame \(describe(p.target))")
}

private func describe(_ r: CGRect) -> String {
    "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))"
}

/// Decides how to split `target`'s area with the window behind it: `target`
/// takes `fraction` of it on `side` and the other window the rest, both
/// easing there together. The area is the stage with Stage Manager on, so
/// only windows already sharing the stage pair up, else the visible frame.
@MainActor
public func pairArrangement(_ side: Action, fraction: Double, for target: AppWindow,
                            stageWait: TimeInterval) throws(ArrangeError) -> Arrangement {
    guard let start = target.frame else {
        throw ArrangeError(description: "\(target.appName)'s window has no frame")
    }
    let stageManager = stageManagerEnabled()
    let p: Placement
    do {
        p = try placement(for: side, fraction: fraction, window: start, displays: currentDisplays(),
                          stages: stageManager ? StageWatcher.shared.frames(waitingUpTo: stageWait) : nil)
    } catch {
        throw ArrangeError(description: error.description)
    }
    guard let other = target.companion(in: p.stage), let otherStart = other.frame else {
        throw ArrangeError(description: "no other window on \(stageManager ? "the stage" : "the display") to pair \(target.appName)'s with")
    }
    let (mine, theirs) = pairFrames(side, fraction: fraction, in: p.stage)
    return Arrangement(
        step: .moveTogether([
            Arrangement.Move(app: target.app, window: target.window, from: start, to: mine),
            Arrangement.Move(app: other.app, window: other.window, from: otherStart, to: theirs),
        ], fps: p.display.fps),
        summary: "\(target.appName) \(describe(mine)) | \(other.appName) \(describe(theirs))")
}

/// Minimizes `target` as its yellow button does: into the Dock, or with Stage
/// Manager on, into the strip of recent apps — where the window keeps
/// reporting itself as not minimized. It works on any window that can be
/// minimized, frontmost or not, without a Window menu.
public func minimizing(_ target: AppWindow) -> Arrangement {
    Arrangement(step: .minimize(target.window), summary: "\(target.appName): minimize")
}

/// Carries out `arrangement`. macOS has no public way to run its own tiling
/// animation to an arbitrary frame, so a moved window eases there over
/// `duration` seconds (0 jumps), the way native tiling does. Blocks for the
/// animation; safe on any thread.
public func perform(_ arrangement: Arrangement, duration: Double) throws(ArrangeError) {
    switch arrangement.step {
    case .press(let item):
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    case .minimize(let window):
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                  kCFBooleanTrue)
        if result != .success {
            throw ArrangeError(description: "the window can't be minimized (\(result.rawValue))")
        }
    case let .move(app, window, start, target, fps, crossesDisplays):
        move([Arrangement.Move(app: app, window: window, from: start, to: target)], fps: fps,
             duration: crossesDisplays ? 0 : duration)
        if crossesDisplays { settle(window, at: target) }
    case let .moveTogether(moves, fps):
        move(moves, fps: fps, duration: duration)
    }
}

/// Once `target`'s window stops moving — macOS animates its own tiling for a
/// moment after the menu item is pressed — moves the pointer to the middle of
/// the window's title bar if it has ended up outside it, so the next swipe can
/// start where the last one did. Gives up waiting after `timeout`. Blocks; safe
/// on any thread.
public func keepPointerOnTitleBar(of target: AppWindow, timeout: TimeInterval = 1) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var last = target.frame
    var unchanged = 0
    while unchanged < 3 && Date() < deadline {
        usleep(50_000)
        let now = target.frame
        if now == last {
            unchanged += 1
        } else {
            unchanged = 0
            last = now
        }
    }
    guard let band = target.titleBar, let pointer = CGEvent(source: nil)?.location,
          let destination = pointerTarget(pointer, titleBar: band) else { return }
    CGWarpMouseCursorPosition(destination)
    // Warping otherwise holds the pointer still for a moment.
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// Moves `moves`' windows to their frames, easing them there together over
/// `duration` seconds (0 jumps).
private func move(_ moves: [Arrangement.Move], fps: Int, duration: Double) {
    // Apps that turn on AXEnhancedUserInterface (Chromium and Electron do for
    // VoiceOver) animate and relayout on every Accessibility resize, which
    // makes each step lag; switch it off while moving.
    let enhanced = "AXEnhancedUserInterface" as CFString
    let wasEnhanced = moves.map { copy($0.app, enhanced as String) as? Bool == true }
    for (m, was) in zip(moves, wasEnhanced) where was {
        AXUIElementSetAttributeValue(m.app, enhanced, kCFBooleanFalse)
    }
    defer {
        for (m, was) in zip(moves, wasEnhanced) where was {
            AXUIElementSetAttributeValue(m.app, enhanced, kCFBooleanTrue)
        }
    }

    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    let moving = moves.filter { $0.from.integral != $0.to.integral }
    if duration > 0 && !moving.isEmpty {
        let began = CACurrentMediaTime()
        let frameInterval = 1.0 / Double(fps)
        while true {
            let elapsed = CACurrentMediaTime() - began
            if elapsed >= duration { break }
            // Ease-out cubic: fast start, gentle landing.
            let t = CGFloat(1 - pow(1 - elapsed / duration, 3))
            for m in moving {
                let step = CGRect(x: lerp(m.from.minX, m.to.minX, t), y: lerp(m.from.minY, m.to.minY, t),
                                  width: lerp(m.from.width, m.to.width, t),
                                  height: lerp(m.from.height, m.to.height, t)).integral
                setPosition(m.window, step.origin)
                setSize(m.window, step.size)
            }
            // A slow app gets fewer, larger steps; the animation still ends on time.
            let next = began + (floor(elapsed / frameInterval) + 1) * frameInterval
            let wait = next - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
    }
    // Size, position, size: the first resize can be clamped while the window
    // still sits at its old origin.
    for m in moves {
        setSize(m.window, m.to.size)
        setPosition(m.window, m.to.origin)
        setSize(m.window, m.to.size)
    }
}

/// Re-applies `target` to a window just moved to another display until it
/// holds. macOS updates which display the window is on a moment after its
/// position changes, and until then a resize is still capped by the old one:
/// a window moved to a larger display can come out narrower than asked. Gives
/// up after a few tries, since some windows only take sizes of their own,
/// such as a terminal's whole character cells.
private func settle(_ window: AXUIElement, at target: CGRect) {
    for wait: useconds_t in [25_000, 50_000, 100_000] {
        guard let now = frame(of: window), now.integral != target.integral else { return }
        usleep(wait)
        setSize(window, target.size)
        setPosition(window, target.origin)
        setSize(window, target.size)
    }
}
