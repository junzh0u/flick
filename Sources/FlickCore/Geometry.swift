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
    /// The name macOS shows for it, as in Window → Move to <name>.
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
    /// The stage, kept to the display's visible frame.
    public let stage: CGRect
    public let target: CGRect
}

public enum PlacementError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDisplays
    case noStage
    case stageOutsideVisibleFrame

    public var description: String {
        switch self {
        case .noDisplays: "no displays"
        case .noStage: "WindowManager reported no Stage Manager stage for this display"
        case .stageOutsideVisibleFrame: "Stage Manager's stage lies outside the display's visible frame"
        }
    }
}

/// Where `action` puts a window now at `window` with Stage Manager on: the
/// matching part of its display's stage. The stage runs under the Dock, so it
/// is kept to the visible frame the way macOS's own window placement is.
/// Stages are matched to displays by position, since their IDs match display
/// IDs only on the built-in display.
public func placement(for action: Action, window: CGRect, displays: [Display],
                      stages: [CGRect]) throws(PlacementError) -> Placement {
    let center = CGPoint(x: window.midX, y: window.midY)
    guard let display = displays.first(where: { $0.frame.contains(center) }) ?? displays.first else {
        throw .noDisplays
    }
    guard let stage = stages.first(where: {
        display.frame.contains(CGPoint(x: $0.midX, y: $0.midY))
    }) else { throw .noStage }
    let usable = stage.intersection(display.visible)
    if usable.isNull || usable.isEmpty { throw .stageOutsideVisibleFrame }
    return Placement(display: display, stage: usable, target: action.frame(in: usable))
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
