import CoreGraphics

/// A window arrangement Flick performs.
public enum Action: String, CaseIterable, Sendable {
    case fill, left, right, top, bottom

    /// The action of macOS's own Window-menu item for this arrangement,
    /// pressed when Stage Manager is off.
    public var menuSelector: String {
        switch self {
        case .fill: "_zoomFill:"
        case .left: "_zoomLeft:"
        case .right: "_zoomRight:"
        case .top: "_zoomTop:"
        case .bottom: "_zoomBottom:"
        }
    }

    /// That item's place in the menu, in English, for messages.
    public var menuPath: [String] {
        switch self {
        case .fill: ["Fill"]
        case .left: ["Move & Resize", "Left"]
        case .right: ["Move & Resize", "Right"]
        case .top: ["Move & Resize", "Top"]
        case .bottom: ["Move & Resize", "Bottom"]
        }
    }

    /// The side across from this one; fill is its own.
    public var opposite: Action {
        switch self {
        case .fill: .fill
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// The part of `r` this arrangement gives the window: `fraction` of it on
    /// that side (fill ignores it). Complementary parts — opposite halves, a
    /// third and two thirds — meet exactly rather than overlap.
    public func frame(in r: CGRect, fraction: Double = 0.5) -> CGRect {
        func part(_ length: CGFloat, _ f: Double) -> CGFloat { (length * f).rounded() }
        switch self {
        case .fill:
            return r
        case .left:
            return CGRect(x: r.minX, y: r.minY, width: part(r.width, fraction), height: r.height)
        case .right:
            let cut = part(r.width, 1 - fraction)
            return CGRect(x: r.minX + cut, y: r.minY, width: r.width - cut, height: r.height)
        case .top:
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: part(r.height, fraction))
        case .bottom:
            let cut = part(r.height, 1 - fraction)
            return CGRect(x: r.minX, y: r.minY + cut, width: r.width, height: r.height - cut)
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
public func actionFrame(_ action: Action, fraction: Double = 0.5, window: CGRect,
                        displays: [Display], stages: [CGRect]?) throws(PlacementError) -> CGRect {
    try placement(for: action, fraction: fraction, window: window, displays: displays,
                  stages: stages).target
}

/// Where `action` puts a window now at `window`: `fraction` of its display's
/// usable area on that side (see usableArea).
public func placement(for action: Action, fraction: Double = 0.5, window: CGRect,
                      displays: [Display], stages: [CGRect]?) throws(PlacementError) -> Placement {
    let display = try display(of: window, in: displays)
    let usable = try usableArea(of: display, stages: stages)
    return Placement(display: display, stage: usable,
                     target: action.frame(in: usable, fraction: fraction))
}

/// The frames that split `area` between two windows: `fraction` of it on
/// `side` for the first, the rest for the second, meeting exactly.
public func pairFrames(_ side: Action, fraction: Double, in area: CGRect) -> (CGRect, CGRect) {
    (side.frame(in: area, fraction: fraction), side.opposite.frame(in: area, fraction: 1 - fraction))
}

/// Repeating a split while ⌘ stays held cycles the window through half, one
/// third and two thirds of the area on that side. Turning a split into a
/// pair, or back, keeps its size, so a window can be sized first and the
/// window behind it then given the rest.
public struct SplitCycle: Sendable {
    public static let fractions: [Double] = [1.0 / 2, 1.0 / 3, 2.0 / 3]

    private var hold: Int?
    private var action: Action?
    private var paired = false
    private var step = 0

    public init() {}

    /// The fraction `action` gives the window next during ⌘ hold `hold` (nil
    /// without ⌘): a half, unless it repeats that hold's last split.
    public func fraction(_ action: Action, paired: Bool = false, hold: Int?) -> Double {
        Self.fractions[nextStep(action, paired: paired, hold: hold)]
    }

    /// Records that `action` — nil for anything else — was just performed
    /// during ⌘ hold `hold`.
    public mutating func performed(_ action: Action?, paired: Bool = false, hold: Int?) {
        step = action.map { nextStep($0, paired: paired, hold: hold) } ?? 0
        self.hold = hold
        self.action = action
        self.paired = paired
    }

    private func nextStep(_ action: Action, paired: Bool, hold: Int?) -> Int {
        guard let hold, hold == self.hold, action == self.action,
              action == .left || action == .right else { return 0 }
        return paired == self.paired ? (step + 1) % Self.fractions.count : step
    }
}

/// How much of `rect` lies inside `area`, from 0 to 1.
func overlap(_ rect: CGRect, with area: CGRect) -> Double {
    let inside = rect.intersection(area)
    guard !inside.isNull, rect.width > 0, rect.height > 0 else { return 0 }
    return Double(inside.width * inside.height / (rect.width * rect.height))
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
