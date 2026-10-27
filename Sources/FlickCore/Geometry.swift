import CoreGraphics

/// A window arrangement Flick performs.
public enum Action: String, CaseIterable, Sendable {
    case fill, left, right, top, bottom

    /// macOS's own Window-menu item for this arrangement, pressed when Stage
    /// Manager is off.
    public var menuPath: [String] {
        switch self {
        case .fill: ["Fill"]
        case .left: ["Move & Resize", "Left"]
        case .right: ["Move & Resize", "Right"]
        case .top: ["Move & Resize", "Top"]
        case .bottom: ["Move & Resize", "Bottom"]
        }
    }

    /// The part of `r` this arrangement gives the window. Opposite halves split
    /// an odd length between them rather than overlap.
    public func frame(in r: CGRect) -> CGRect {
        func half(_ length: CGFloat) -> CGFloat { (length / 2).rounded() }
        switch self {
        case .fill:
            return r
        case .left:
            return CGRect(x: r.minX, y: r.minY, width: half(r.width), height: r.height)
        case .right:
            return CGRect(x: r.minX + half(r.width), y: r.minY,
                          width: r.width - half(r.width), height: r.height)
        case .top:
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: half(r.height))
        case .bottom:
            return CGRect(x: r.minX, y: r.minY + half(r.height),
                          width: r.width, height: r.height - half(r.height))
        }
    }
}

/// A display in Accessibility coordinates: origin at the main display's top
/// left, y growing down.
public struct Display: Equatable, Sendable {
    public let frame: CGRect
    public let visible: CGRect
    public let fps: Int
    /// The name macOS shows for it, e.g. in System Settings → Displays.
    public let name: String

    public init(frame: CGRect, visible: CGRect, fps: Int, name: String = "") {
        self.frame = frame
        self.visible = visible
        self.fps = fps
        self.name = name
    }
}

public enum DisplayStep: String, CaseIterable, Sendable {
    case previous, next
}

/// The display before or after the one showing `window`, in left-to-right
/// order (top to bottom where they line up), wrapping around. Nil with fewer
/// than two displays.
public func neighbor(of window: CGRect, _ step: DisplayStep, in displays: [Display]) -> Display? {
    guard displays.count > 1 else { return nil }
    let ordered = displays.sorted { ($0.frame.midX, $0.frame.midY) < ($1.frame.midX, $1.frame.midY) }
    let center = CGPoint(x: window.midX, y: window.midY)
    let current = ordered.firstIndex(where: { $0.frame.contains(center) }) ?? 0
    let offset = step == .next ? 1 : ordered.count - 1
    return ordered[(current + offset) % ordered.count]
}

public struct Placement: Equatable, Sendable {
    public let display: Display
    /// Where windows are arranged on the display (see usableArea).
    public let stage: CGRect
    public let target: CGRect
}

public enum PlacementError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDisplays
    case noOtherDisplay
    case noStage
    case stageOutsideVisibleFrame

    public var description: String {
        switch self {
        case .noDisplays: "no displays"
        case .noOtherDisplay: "there is no other display"
        case .noStage: "WindowManager reported no Stage Manager stage for this display"
        case .stageOutsideVisibleFrame: "Stage Manager's stage lies outside the display's visible frame"
        }
    }
}

/// The display showing the centre of `window`, or else the first.
func display(of window: CGRect, in displays: [Display]) throws(PlacementError) -> Display {
    let center = CGPoint(x: window.midX, y: window.midY)
    guard let display = displays.first(where: { $0.frame.contains(center) }) ?? displays.first else {
        throw .noDisplays
    }
    return display
}

/// Where windows are arranged on `display`: with Stage Manager on (`stages`
/// given), its stage, kept to the visible frame the way macOS's own window
/// placement is, since the stage runs under the Dock; otherwise its visible
/// frame. Stages are matched to displays by position, since their IDs match
/// display IDs only on the built-in display.
public func usableArea(of display: Display, stages: [CGRect]?) throws(PlacementError) -> CGRect {
    guard let stages else { return display.visible }
    guard let stage = stages.first(where: {
        display.frame.contains(CGPoint(x: $0.midX, y: $0.midY))
    }) else { throw .noStage }
    let usable = stage.intersection(display.visible)
    if usable.isNull || usable.isEmpty { throw .stageOutsideVisibleFrame }
    return usable
}

/// Where `action` puts a window now at `window`: the matching part of its
/// display's usable area (see usableArea). With Stage Manager off, macOS's own
/// command does the arranging; this is where it lands short of any margins
/// macOS adds between tiled windows.
public func actionFrame(_ action: Action, window: CGRect, displays: [Display],
                        stages: [CGRect]?) throws(PlacementError) -> CGRect {
    action.frame(in: try usableArea(of: try display(of: window, in: displays), stages: stages))
}

/// Where `action` puts a window now at `window` with Stage Manager on: the
/// matching part of its display's stage.
public func placement(for action: Action, window: CGRect, displays: [Display],
                      stages: [CGRect]) throws(PlacementError) -> Placement {
    let display = try display(of: window, in: displays)
    let usable = try usableArea(of: display, stages: stages)
    return Placement(display: display, stage: usable, target: action.frame(in: usable))
}

/// `window`'s frame mapped from `source` to `target` in proportion, so it keeps
/// its relative position and size: a left half stays a left half. Kept within
/// `target`, so a window hanging off one display doesn't land off the next.
public func proportionalFrame(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
    let sx = target.width / source.width, sy = target.height / source.height
    let width = min((window.width * sx).rounded(), target.width)
    let height = min((window.height * sy).rounded(), target.height)
    let x = (target.minX + (window.minX - source.minX) * sx).rounded()
    let y = (target.minY + (window.minY - source.minY) * sy).rounded()
    return CGRect(x: min(max(x, target.minX), target.maxX - width),
                  y: min(max(y, target.minY), target.maxY - height),
                  width: width, height: height)
}

/// Where `step` moves a window now at `window`: the previous or next display,
/// at the same position and size relative to each display's usable area.
public func displayMove(window: CGRect, _ step: DisplayStep, displays: [Display],
                        stages: [CGRect]?) throws(PlacementError) -> Placement {
    let source = try display(of: window, in: displays)
    guard let target = neighbor(of: window, step, in: displays) else { throw .noOtherDisplay }
    let from = try usableArea(of: source, stages: stages)
    let to = try usableArea(of: target, stages: stages)
    return Placement(display: target, stage: to,
                     target: proportionalFrame(window, from: from, to: to))
}

/// Where to put the pointer after arranging a window whose title-bar band is
/// `band`: its centre, or nil when the pointer is already in it.
public func pointerTarget(_ pointer: CGPoint, titleBar band: CGRect) -> CGPoint? {
    band.contains(pointer) ? nil : CGPoint(x: band.midX.rounded(), y: band.midY.rounded())
}

/// The title-bar band of a window at `window`. Traffic lights sit centred in
/// the title bar, unified toolbar or tab strip, whichever the window has, so
/// the band reaches twice as far below the window's top as the close button's
/// centre. Windows without one get a plain title bar's height.
public func titleBarBand(window: CGRect, closeButton: CGRect?) -> CGRect {
    let plainTitleBar: CGFloat = 28
    var height = plainTitleBar
    if let button = closeButton, !button.isEmpty, button.midY > window.minY {
        height = 2 * (button.midY - window.minY)
    }
    return CGRect(x: window.minX, y: window.minY, width: window.width,
                  height: min(height, window.height))
}
