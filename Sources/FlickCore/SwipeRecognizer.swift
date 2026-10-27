/// The way a swipe's fingers moved.
public enum SwipeDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

/// A scroll event's gesture phase (CGEvent's kCGScrollPhase* values).
public enum ScrollPhase: Sendable, Equatable {
    case none, mayBegin, began, changed, ended, cancelled

    public init(raw: Int64) {
        switch raw {
        case 1: self = .began
        case 2: self = .changed
        case 4: self = .ended
        case 8: self = .cancelled
        case 128: self = .mayBegin
        default: self = .none
        }
    }
}

/// A scroll event's momentum phase (CGEvent's kCGMomentumScrollPhase* values).
public enum MomentumPhase: Sendable, Equatable {
    case none, begin, `continue`, end

    public init(raw: Int64) {
        switch raw {
        case 1: self = .begin
        case 2: self = .continue
        case 3: self = .end
        default: self = .none
        }
    }
}

/// What to do with a scroll event.
public enum Verdict: Equatable, Sendable {
    /// Deliver it as usual.
    case pass
    /// Drop it: it belongs to a swipe Flick handles.
    case swallow
    /// Drop it, and the swipe it ends went this way.
    case fire(SwipeDirection)
}

/// Recognizes two-finger swipes from the trackpad's stream of phased scroll
/// events, among the gestures that start where Flick acts (`startsOnTarget`:
/// a window's title bar, or with ⌘ held, anywhere in the window).
///
/// A swipe is decided when its fingers lift, from the overall finger travel,
/// so it can still be steered or abandoned mid-swipe. All of its events are
/// swallowed, including the momentum scroll after it, so the window under it
/// never scrolls; other gestures pass untouched.
public struct SwipeRecognizer: Sendable {
    /// Finger travel, in scroll points along the dominant axis, a swipe needs.
    public var threshold: Double

    private enum State: Equatable {
        case idle
        case ignoring
        case tracking(x: Double, y: Double)
        /// Swallowing the momentum scroll after a swipe.
        case coasting
    }

    private var state = State.idle

    public init(threshold: Double = 50) {
        self.threshold = threshold
    }

    /// The way the swipe in progress would fire if the fingers lifted now, or
    /// nil when no swipe is in progress or it hasn't travelled far enough.
    public var pending: SwipeDirection? {
        guard case .tracking(let x, let y) = state else { return nil }
        return classify(x: x, y: y)
    }

    /// Feeds one trackpad scroll event. `deltaX` and `deltaY` are its
    /// scrolling deltas and `inverted` its isDirectionInvertedFromDevice
    /// ("natural scrolling"). `startsOnTarget` is asked once per gesture, on
    /// its first event.
    public mutating func handle(phase: ScrollPhase, momentum: MomentumPhase,
                                deltaX: Double, deltaY: Double, inverted: Bool,
                                startsOnTarget: () -> Bool) -> Verdict {
        // With natural scrolling the content follows the fingers, so the
        // deltas point the way they moved (x right, y down); otherwise the
        // opposite way.
        let x = inverted ? deltaX : -deltaX
        let y = inverted ? deltaY : -deltaY

        switch phase {
        case .mayBegin, .began:
            switch state {
            case .tracking(let tx, let ty):
                state = .tracking(x: tx + x, y: ty + y)
                return .swallow
            case .ignoring where phase == .began:
                return .pass
            default:
                if startsOnTarget() {
                    state = .tracking(x: x, y: y)
                    return .swallow
                }
                state = .ignoring
                return .pass
            }
        case .changed:
            guard case .tracking(let tx, let ty) = state else { return .pass }
            state = .tracking(x: tx + x, y: ty + y)
            return .swallow
        case .ended:
            guard case .tracking(let tx, let ty) = state else {
                state = .idle
                return .pass
            }
            state = .coasting
            return classify(x: tx + x, y: ty + y).map(Verdict.fire) ?? .swallow
        case .cancelled:
            guard case .tracking = state else {
                state = .idle
                return .pass
            }
            state = .idle
            return .swallow
        case .none:
            guard state == .coasting, momentum != .none else { return .pass }
            if momentum == .end { state = .idle }
            return .swallow
        }
    }

    private func classify(x: Double, y: Double) -> SwipeDirection? {
        if abs(x) >= abs(y) {
            guard abs(x) >= threshold else { return nil }
            return x > 0 ? .right : .left
        }
        guard abs(y) >= threshold else { return nil }
        return y > 0 ? .down : .up
    }
}
