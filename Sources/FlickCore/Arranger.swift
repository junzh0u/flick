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
        /// Press the Window-menu item titled this once the app shows it.
        case pressWhenShown(app: AXUIElement, title: String)
        case move(app: AXUIElement, window: AXUIElement, from: CGRect, to: CGRect, fps: Int)
        case minimize(AXUIElement)
    }

    let step: Step
    /// What it will do, e.g. "Safari: Window → Fill" or
    /// "Safari: stage 218 33 1510 1084, frame 218 33 755 1084".
    public let summary: String
}

/// Decides how to carry out `action` on `target`. With Stage Manager off this
/// is macOS's own Window-menu command; with it on, Fill would cover the strip
/// of recent apps, so the window instead takes the matching part of its
/// display's stage — the area beside the strip where macOS itself places new
/// windows.
@MainActor
public func arrangement(_ action: Action, for target: AppWindow,
                        stageWait: TimeInterval) throws(ArrangeError) -> Arrangement {
    let name = target.appName
    if !stageManagerEnabled() {
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
        p = try placement(for: action, window: start, displays: currentDisplays(),
                          stages: StageWatcher.shared.frames(waitingUpTo: stageWait))
    } catch {
        throw ArrangeError(description: error.description)
    }
    func describe(_ r: CGRect) -> String {
        "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))"
    }
    return Arrangement(
        step: .move(app: target.app, window: target.window, from: start, to: p.target,
                    fps: p.display.fps),
        summary: "\(name): stage \(describe(p.stage)), frame \(describe(p.target))")
}

/// Decides how to move `target` to the previous or next display: macOS's own
/// Window → Move to <display>, which keeps the window's layout and leaves
/// Stage Manager to place it. macOS lists that item only in the frontmost
/// app's Window menu, so `target` must be brought to the front first.
@MainActor
public func arrangement(_ step: DisplayStep, for target: AppWindow) throws(ArrangeError) -> Arrangement {
    guard let start = target.frame else {
        throw ArrangeError(description: "\(target.appName)'s window has no frame")
    }
    guard let display = neighbor(of: start, step, in: currentDisplays()) else {
        throw ArrangeError(description: "there is no other display")
    }
    let item = "Move to \(display.name)"
    return Arrangement(step: .pressWhenShown(app: target.app, title: item),
                       summary: "\(target.appName): Window → \(item)")
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
/// animation, or up to `menuWait` for a Window-menu item to show; safe on any
/// thread.
public func perform(_ arrangement: Arrangement, duration: Double,
                    menuWait: TimeInterval = 0.5) throws(ArrangeError) {
    switch arrangement.step {
    case .press(let item):
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    case let .pressWhenShown(app, title):
        let deadline = Date(timeIntervalSinceNow: menuWait)
        while true {
            if let item = windowMenuItem(app, where: { $0 == title }) {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                return
            }
            if Date() >= deadline { throw ArrangeError(description: "no Window → \(title)") }
            usleep(20_000)
        }
    case .minimize(let window):
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                  kCFBooleanTrue)
        if result != .success {
            throw ArrangeError(description: "the window can't be minimized (\(result.rawValue))")
        }
    case let .move(app, window, start, target, fps):
        move(app: app, window: window, from: start, to: target, fps: fps, duration: duration)
    }
}

private func move(app: AXUIElement, window: AXUIElement, from start: CGRect, to target: CGRect,
                  fps: Int, duration: Double) {
    // Apps that turn on AXEnhancedUserInterface (Chromium and Electron do for
    // VoiceOver) animate and relayout on every Accessibility resize, which
    // makes each step lag; switch it off while moving.
    let enhanced = "AXEnhancedUserInterface" as CFString
    let wasEnhanced = copy(app, enhanced as String) as? Bool == true
    if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }
    defer { if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) } }

    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    if duration > 0 && start.integral != target.integral {
        let began = CACurrentMediaTime()
        let frameInterval = 1.0 / Double(fps)
        while true {
            let elapsed = CACurrentMediaTime() - began
            if elapsed >= duration { break }
            // Ease-out cubic: fast start, gentle landing.
            let t = CGFloat(1 - pow(1 - elapsed / duration, 3))
            let step = CGRect(x: lerp(start.minX, target.minX, t), y: lerp(start.minY, target.minY, t),
                              width: lerp(start.width, target.width, t),
                              height: lerp(start.height, target.height, t)).integral
            setPosition(window, step.origin)
            setSize(window, step.size)
            // A slow app gets fewer, larger steps; the animation still ends on time.
            let next = began + (floor(elapsed / frameInterval) + 1) * frameInterval
            let wait = next - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
    }
    // Size, position, size: the first resize can be clamped while the window
    // still sits at its old origin.
    setSize(window, target.size)
    setPosition(window, target.origin)
    setSize(window, target.size)
}
