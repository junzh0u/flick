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

    @Test func pendingFollowsTheSwipeUntilItEnds() {
        var r = SwipeRecognizer(threshold: 50)
        let events: [(ScrollPhase, Double, Double)] = [
            (.mayBegin, 0, 0), (.began, -30, 0), (.changed, -30, 0), (.changed, 0, -80),
            (.changed, 0, 0), (.ended, 0, 0),
        ]
        var seen: [SwipeDirection?] = []
        for (phase, dx, dy) in events {
            _ = r.handle(phase: phase, momentum: .none, deltaX: dx, deltaY: dy, inverted: true) { true }
            seen.append(r.pending)
        }
        #expect(seen == [nil, nil, .left, .up, .up, nil])
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

@Suite struct PinchRecognizerTests {
    private func feed(_ r: inout PinchRecognizer, onTarget: Bool,
                      _ events: [(ScrollPhase, Double)]) -> [PinchVerdict] {
        events.map { phase, m in r.handle(phase: phase, magnification: m) { onTarget } }
    }

    @Test func pinchingInFarEnoughFires() {
        var r = PinchRecognizer(threshold: 0.3)
        #expect(feed(&r, onTarget: true, [(.began, -0.1), (.changed, -0.15), (.changed, -0.1),
                                          (.ended, 0)])
            == [.swallow, .swallow, .swallow, .fire])
    }

    @Test func pendingTracksTheTotal() {
        var r = PinchRecognizer(threshold: 0.3)
        _ = feed(&r, onTarget: true, [(.began, -0.2)])
        #expect(!r.pending)
        _ = feed(&r, onTarget: true, [(.changed, -0.2)])
        #expect(r.pending)
        _ = feed(&r, onTarget: true, [(.changed, 0.3)])
        #expect(!r.pending)
        _ = feed(&r, onTarget: true, [(.ended, 0)])
        #expect(!r.pending)
    }

    @Test func pinchingOutOrNotFarEnoughIsSwallowedWithoutFiring() {
        var r = PinchRecognizer(threshold: 0.3)
        #expect(feed(&r, onTarget: true, [(.began, 0.2), (.changed, 0.4), (.ended, 0)]).last == .swallow)
        #expect(feed(&r, onTarget: true, [(.began, -0.1), (.ended, -0.1)]).last == .swallow)
    }

    @Test func pinchesElsewherePassThrough() {
        var r = PinchRecognizer(threshold: 0.3)
        #expect(feed(&r, onTarget: false, [(.began, -0.5), (.changed, -0.5), (.ended, 0)])
            == [.pass, .pass, .pass])
    }
}

@Suite struct GeometryTests {
    let display = Display(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          visible: CGRect(x: 0, y: 33, width: 1728, height: 1084), fps: 120)
    let external = Display(frame: CGRect(x: 1728, y: -200, width: 2560, height: 1440),
                           visible: CGRect(x: 1728, y: -175, width: 2560, height: 1415), fps: 60)

    @Test func actionFrameUsesTheVisibleFrameWithStageManagerOff() throws {
        let window = CGRect(x: 100, y: 100, width: 500, height: 500)
        #expect(try actionFrame(.right, window: window, displays: [display, external], stages: nil)
            == CGRect(x: 864, y: 33, width: 864, height: 1084))
    }

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

    @Test func neighborsRunLeftToRightAndWrap() {
        let left = Display(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                           visible: .zero, fps: 60, name: "left")
        let builtIn = Display(frame: display.frame, visible: display.visible, fps: 120, name: "built-in")
        let right = Display(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                            visible: .zero, fps: 60, name: "right")
        let displays = [builtIn, right, left]
        let window = CGRect(x: 100, y: 100, width: 500, height: 500)
        #expect(neighbor(of: window, .next, in: displays)?.name == "right")
        #expect(neighbor(of: window, .previous, in: displays)?.name == "left")
        let onRight = window.offsetBy(dx: 2000, dy: 0)
        #expect(neighbor(of: onRight, .next, in: displays)?.name == "left")
        #expect(neighbor(of: window, .next, in: [builtIn]) == nil)
    }

    @Test func proportionalFrameKeepsRelativePlaceAndSize() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let to = CGRect(x: 2000, y: -100, width: 2000, height: 1500)
        #expect(proportionalFrame(from, from: from, to: to) == to)
        #expect(proportionalFrame(CGRect(x: 500, y: 0, width: 500, height: 500), from: from, to: to)
            == CGRect(x: 3000, y: -100, width: 1000, height: 1500))
        #expect(proportionalFrame(CGRect(x: 100, y: 50, width: 300, height: 200), from: from, to: to)
            == CGRect(x: 2200, y: 50, width: 600, height: 600))
    }

    @Test func proportionalFrameStaysWithinTheTarget() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let to = CGRect(x: 2000, y: 0, width: 1000, height: 500)
        #expect(proportionalFrame(CGRect(x: 900, y: -50, width: 400, height: 600), from: from, to: to)
            == CGRect(x: 2600, y: 0, width: 400, height: 500))
    }

    @Test func displayMoveMapsBetweenStagesWithStageManagerOn() throws {
        let stages = [CGRect(x: 1928, y: -200, width: 2360, height: 1440),
                      CGRect(x: 218, y: 0, width: 1510, height: 1117)]
        let leftHalf = CGRect(x: 218, y: 33, width: 755, height: 1084)
        let p = try displayMove(window: leftHalf, .next, displays: [display, external], stages: stages)
        #expect(p.display == external)
        #expect(p.stage == CGRect(x: 1928, y: -175, width: 2360, height: 1415))
        #expect(p.target == CGRect(x: 1928, y: -175, width: 1180, height: 1415))
    }

    @Test func displayMoveUsesVisibleFramesWithStageManagerOff() throws {
        let p = try displayMove(window: display.visible, .previous, displays: [display, external],
                                stages: nil)
        #expect(p.target == external.visible)
        #expect(throws: PlacementError.noOtherDisplay) {
            try displayMove(window: display.visible, .next, displays: [display], stages: nil)
        }
    }

    @Test func pointerMovesToTheTitleBarsMiddleOnlyWhenOutsideIt() {
        let band = CGRect(x: 100, y: 200, width: 801, height: 52)
        #expect(pointerTarget(CGPoint(x: 150, y: 210), titleBar: band) == nil)
        #expect(pointerTarget(CGPoint(x: 150, y: 400), titleBar: band) == CGPoint(x: 501, y: 226))
    }

    @Test func titleBarBandIsTwiceTheCloseButtonsDepth() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let unifiedToolbar = CGRect(x: 120, y: 219, width: 14, height: 14)
        #expect(titleBarBand(window: window, closeButton: unifiedToolbar).height == 52)
        #expect(titleBarBand(window: window, closeButton: nil).height == 28)
    }
}
