import CoreGraphics
import Testing
@testable import FlickCore

/// Feeds a gesture's events, as (phase, momentum, dx, dy), to a recognizer
/// with natural scrolling on, where deltas point the way the fingers move.
private func feed(_ recognizer: inout SwipeRecognizer, onTitleBar: Bool,
                  _ events: [(ScrollPhase, MomentumPhase, Double, Double)],
                  inverted: Bool = true) -> (verdicts: [Verdict], asked: Int) {
    var asked = 0
    let verdicts = events.map { phase, momentum, dx, dy in
        recognizer.handle(phase: phase, momentum: momentum, deltaX: dx, deltaY: dy,
                          inverted: inverted) {
            asked += 1
            return onTitleBar
        }
    }
    return (verdicts, asked)
}

private func swipe(_ dx: Double, _ dy: Double) -> [(ScrollPhase, MomentumPhase, Double, Double)] {
    [(.mayBegin, .none, 0, 0), (.began, .none, dx / 4, dy / 4), (.changed, .none, dx / 4, dy / 4),
     (.changed, .none, dx / 4, dy / 4), (.ended, .none, dx / 4, dy / 4)]
}

private let momentum: [(ScrollPhase, MomentumPhase, Double, Double)] = [
    (.none, .begin, 5, 0), (.none, .continue, 3, 0), (.none, .end, 0, 0),
]

@Suite struct SwipeRecognizerTests {
    @Test(arguments: [
        (0.0, -80.0, SwipeDirection.up), (0, 80, .down), (-80, 0, .left), (80, 0, .right),
    ])
    func firesTheFingersDirectionOnRelease(dx: Double, dy: Double, direction: SwipeDirection) {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, asked) = feed(&r, onTitleBar: true, swipe(dx, dy))
        #expect(verdicts == [.swallow, .swallow, .swallow, .swallow, .fire(direction)])
        #expect(asked == 1)
    }

    @Test func traditionalScrollingReversesTheDeltas() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, _) = feed(&r, onTitleBar: true, swipe(0, 80), inverted: false)
        #expect(verdicts.last == .fire(.up))
    }

    @Test func dominantAxisDecides() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, _) = feed(&r, onTitleBar: true, swipe(90, -60))
        #expect(verdicts.last == .fire(.right))
    }

    @Test func shortSwipeIsSwallowedWithoutFiring() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, _) = feed(&r, onTitleBar: true, swipe(0, -40))
        #expect(verdicts.last == .swallow)
    }

    @Test func gestureOffTheTitleBarPassesThroughWithItsMomentum() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, asked) = feed(&r, onTitleBar: false, swipe(0, -200) + momentum)
        #expect(verdicts.allSatisfy { $0 == .pass })
        #expect(asked == 1)
    }

    @Test func momentumAfterASwipeIsSwallowedUntilItEnds() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, _) = feed(&r, onTitleBar: true, swipe(0, -200) + momentum
            + [(.none, .begin, 5, 0)])
        #expect(Array(verdicts.suffix(4)) == [.swallow, .swallow, .swallow, .pass])
    }

    @Test func cancelledGestureNeverFires() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, _) = feed(&r, onTitleBar: true, [
            (.mayBegin, .none, 0, 0), (.began, .none, 0, -200), (.cancelled, .none, 0, 0),
        ])
        #expect(verdicts == [.swallow, .swallow, .swallow])
    }

    @Test func newGestureDuringMomentumIsDecidedAfresh() {
        var r = SwipeRecognizer(threshold: 50)
        _ = feed(&r, onTitleBar: true, swipe(0, -200) + [(.none, .begin, 5, 0)])
        let (verdicts, asked) = feed(&r, onTitleBar: false, swipe(0, -200))
        #expect(verdicts.allSatisfy { $0 == .pass })
        #expect(asked == 1)
    }

    @Test func gestureWithoutMayBeginIsDecidedOnBegan() {
        var r = SwipeRecognizer(threshold: 50)
        let (verdicts, asked) = feed(&r, onTitleBar: true, Array(swipe(-200, 0).dropFirst()))
        #expect(verdicts.last == .fire(.left))
        #expect(asked == 1)
    }
}

@Suite struct GeometryTests {
    let display = Display(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          visible: CGRect(x: 0, y: 33, width: 1728, height: 1084), fps: 120)
    let external = Display(frame: CGRect(x: 1728, y: -200, width: 2560, height: 1440),
                           visible: CGRect(x: 1728, y: -175, width: 2560, height: 1415), fps: 60)

    @Test func halvesSplitAnOddLengthWithoutOverlap() {
        let r = CGRect(x: 10, y: 20, width: 101, height: 51)
        #expect(Action.left.frame(in: r).maxX == Action.right.frame(in: r).minX)
        #expect(Action.left.frame(in: r).width + Action.right.frame(in: r).width == 101)
        #expect(Action.top.frame(in: r).maxY == Action.bottom.frame(in: r).minY)
        #expect(Action.bottom.frame(in: r).maxY == r.maxY)
    }

    @Test func placementUsesTheStageOfTheWindowsDisplayWithinItsVisibleFrame() throws {
        let stages = [CGRect(x: 1928, y: -200, width: 2360, height: 1440),
                      CGRect(x: 218, y: 0, width: 1510, height: 1117)]
        let p = try placement(for: .left, window: CGRect(x: 100, y: 100, width: 500, height: 500),
                              displays: [external, display], stages: stages)
        #expect(p.stage == CGRect(x: 218, y: 33, width: 1510, height: 1084))
        #expect(p.target == CGRect(x: 218, y: 33, width: 755, height: 1084))
        #expect(p.display == display)
    }

    @Test func placementFailsWithoutAStageOnTheDisplay() {
        #expect(throws: PlacementError.noStage) {
            try placement(for: .fill, window: CGRect(x: 2000, y: 0, width: 500, height: 500),
                          displays: [display, external],
                          stages: [CGRect(x: 218, y: 0, width: 1510, height: 1117)])
        }
    }

    @Test func titleBarBandIsTwiceTheCloseButtonsDepth() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let unifiedToolbar = CGRect(x: 120, y: 219, width: 14, height: 14)
        #expect(titleBarBand(window: window, closeButton: unifiedToolbar).height == 52)
        #expect(titleBarBand(window: window, closeButton: nil).height == 28)
    }
}
