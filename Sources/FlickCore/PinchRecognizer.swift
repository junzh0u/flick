/// Recognizes a pinch in from the trackpad's phased magnify events, among
/// pinches that start where Flick acts (`startsOnTarget`), the way
/// SwipeRecognizer does swipes. All events of such a pinch are swallowed, so
/// the app under it never zooms; it fires when the fingers lift having closed
/// by at least `threshold` in total magnification.
public struct PinchRecognizer: Sendable {
    /// Total magnification, negative for pinching in, a pinch needs.
    public var threshold: Double

    private enum State: Equatable {
        case idle
        case ignoring
        case tracking(Double)
    }

    private var state = State.idle

    public init(threshold: Double = 0.3) {
        self.threshold = threshold
    }

    /// Whether the pinch in progress would fire if the fingers lifted now.
    public var pending: Bool {
        guard case .tracking(let total) = state else { return false }
        return total <= -threshold
    }

    /// Feeds one magnify event: its phase and magnification. `startsOnTarget`
    /// is asked once per pinch, on its first event.
    public mutating func handle(phase: ScrollPhase, magnification: Double,
                                startsOnTarget: () -> Bool) -> PinchVerdict {
        switch phase {
        case .mayBegin, .began:
            if case .tracking(let total) = state {
                state = .tracking(total + magnification)
                return .swallow
            }
            if startsOnTarget() {
                state = .tracking(magnification)
                return .swallow
            }
            state = .ignoring
            return .pass
        case .changed:
            guard case .tracking(let total) = state else { return .pass }
            state = .tracking(total + magnification)
            return .swallow
        case .ended:
            guard case .tracking(let total) = state else {
                state = .idle
                return .pass
            }
            state = .idle
            return total + magnification <= -threshold ? .fire : .swallow
        case .cancelled:
            guard case .tracking = state else {
                state = .idle
                return .pass
            }
            state = .idle
            return .swallow
        case .none:
            return state == .ignoring || state == .idle ? .pass : .swallow
        }
    }
}

/// What to do with a magnify event.
public enum PinchVerdict: Equatable, Sendable {
    case pass
    case swallow
    /// Drop it: it ends a pinch in.
    case fire
}
