import XCTest
@testable import Lockpaw

final class GazeTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// An upper-body box centered at `x` (Vision coordinates: normalized, y up).
    private func person(x: CGFloat, width: CGFloat = 0.2, top: CGFloat = 0.9, height: CGFloat = 0.6) -> CGRect {
        CGRect(x: x - width / 2, y: top - height, width: width, height: height)
    }

    // MARK: - Target

    func testNobodyMeansNoTarget() {
        XCTAssertNil(GazeTracker.target(for: []))
        XCTAssertNil(GazeTracker.target(for: [.zero]))
    }

    func testCameraLeftIsScreenRight() throws {
        // Image-left in the camera is the viewer's right: the mascot looks right (+x).
        let target = try XCTUnwrap(GazeTracker.target(for: [person(x: 0.1)]))
        XCTAssertEqual(target.x, 0.8, accuracy: 0.0001)
        let other = try XCTUnwrap(GazeTracker.target(for: [person(x: 0.9)]))
        XCTAssertEqual(other.x, -0.8, accuracy: 0.0001)
    }

    func testLooksAtTheHeadAndUpForATallPerson() throws {
        // Head = 0.9 - 0.15 × 0.6 = 0.81 → gaze y = 1 - 1.62 = -0.62 (looking up).
        let target = try XCTUnwrap(GazeTracker.target(for: [person(x: 0.5)]))
        XCTAssertEqual(target.x, 0, accuracy: 0.0001)
        XCTAssertEqual(target.y, -0.62, accuracy: 0.0001)
    }

    func testFollowsTheNearestPerson() throws {
        let far = person(x: 0.9, width: 0.1, height: 0.3)
        let near = person(x: 0.2, width: 0.4)
        let target = try XCTUnwrap(GazeTracker.target(for: [far, near]))
        XCTAssertEqual(target.x, 0.6, accuracy: 0.0001)
    }

    // MARK: - Smoothing

    private let frame: TimeInterval = 0.1

    /// Feeds the same people for `frames` frames starting at frame `start`; returns the last gaze.
    @discardableResult
    private func feed(_ tracker: inout GazeTracker, _ people: [CGRect], frames: Int, from start: Int) -> CGPoint {
        var gaze = tracker.gaze
        for i in start..<(start + frames) { gaze = tracker.update(people: people, at: t0 + Double(i) * frame) }
        return gaze
    }

    func testFirstFrameDoesNotJump() {
        var tracker = GazeTracker()
        XCTAssertEqual(tracker.update(people: [person(x: 0.1)], at: t0), .zero)
    }

    func testEasesTowardThePerson() {
        var tracker = GazeTracker()
        let step = feed(&tracker, [person(x: 0.1)], frames: GazeTracker.framesToConfirm, from: 0)
        XCTAssertGreaterThan(step.x, 0)
        XCTAssertLessThan(step.x, 0.8)
        let gaze = feed(&tracker, [person(x: 0.1)], frames: 30, from: GazeTracker.framesToConfirm)
        XCTAssertEqual(gaze.x, 0.8, accuracy: 0.01)
    }

    func testHoldsBrieflyAfterLosingThePerson() {
        var tracker = GazeTracker()
        for i in 0...30 { tracker.update(people: [person(x: 0.1)], at: t0 + Double(i) * 0.1) }
        let held = tracker.update(people: [], at: t0 + 3.0 + GazeTracker.holdAfterLoss - 0.1)
        XCTAssertEqual(held.x, 0.8, accuracy: 0.01, "a dropped frame or two is not a blink")
    }

    func testDriftsHomeOnceTheyreGone() {
        var tracker = GazeTracker()
        for i in 0...30 { tracker.update(people: [person(x: 0.1)], at: t0 + Double(i) * 0.1) }
        var gaze = CGPoint.zero
        for i in 1...60 { gaze = tracker.update(people: [], at: t0 + 3.0 + Double(i) * 0.1) }
        XCTAssertEqual(gaze.x, 0, accuracy: 0.01)
    }

    func testALongPauseCannotOvershoot() {
        var tracker = GazeTracker()
        feed(&tracker, [person(x: 0.1)], frames: GazeTracker.framesToConfirm, from: 0)
        let gaze = tracker.update(people: [person(x: 0.1)], at: t0 + 3600)
        XCTAssertGreaterThan(gaze.x, 0)
        XCTAssertLessThanOrEqual(gaze.x, 0.8)
    }

    func testResetLooksStraightAhead() {
        var tracker = GazeTracker()
        for i in 0...10 { tracker.update(people: [person(x: 0.1)], at: t0 + Double(i) * 0.1) }
        tracker.reset()
        XCTAssertEqual(tracker.gaze, .zero)
    }

    // MARK: - Confirmation

    func testAPersonMustBeSeenThreeFramesInARow() {
        XCTAssertEqual(GazeTracker.framesToConfirm, 3)
        var tracker = GazeTracker()
        XCTAssertEqual(feed(&tracker, [person(x: 0.1)], frames: 2, from: 0), .zero, "two frames is not enough")
        XCTAssertGreaterThan(feed(&tracker, [person(x: 0.1)], frames: 1, from: 2).x, 0, "the third frame starts the follow")
    }

    func testAGapRestartsTheCount() {
        var tracker = GazeTracker()
        feed(&tracker, [person(x: 0.1)], frames: 2, from: 0)
        feed(&tracker, [], frames: 1, from: 2)
        XCTAssertEqual(feed(&tracker, [person(x: 0.1)], frames: 2, from: 3), .zero, "seen 2, gap, seen 2: never three in a row")
        XCTAssertGreaterThan(feed(&tracker, [person(x: 0.1)], frames: 1, from: 5).x, 0)
    }

    func testFlickeringDetectionsNeverMoveTheEyes() {
        var tracker = GazeTracker()
        for i in 0..<60 {
            let people = i % 3 == 2 ? [] : [person(x: 0.1)]
            XCTAssertEqual(tracker.update(people: people, at: t0 + Double(i) * frame), .zero)
        }
    }

    func testADroppedFrameWhileFollowingNeedsNoNewCount() {
        var tracker = GazeTracker()
        feed(&tracker, [person(x: 0.1)], frames: 40, from: 0)
        feed(&tracker, [], frames: 1, from: 40)
        // They moved during the dropped frame; the very next sighting is followed.
        let before = tracker.gaze
        let after = feed(&tracker, [person(x: 0.3)], frames: 1, from: 41)
        XCTAssertLessThan(after.x, before.x)
    }

    func testAfterTheyLeaveTheNextPersonIsCountedAfresh() {
        var tracker = GazeTracker()
        feed(&tracker, [person(x: 0.5)], frames: 10, from: 0)
        feed(&tracker, [], frames: 100, from: 10) // well past the hold; eyes are home
        let home = tracker.gaze
        XCTAssertEqual(home.x, 0, accuracy: 0.001)
        XCTAssertEqual(feed(&tracker, [person(x: 0.1)], frames: 2, from: 110).x, home.x, accuracy: 0.001)
        XCTAssertGreaterThan(feed(&tracker, [person(x: 0.1)], frames: 1, from: 112).x, 0.01)
    }

    // MARK: - Staying with one person

    func testPickStaysWithWhoeverIsClosestToTheTarget() {
        let a = person(x: 0.2)
        let b = person(x: 0.8, width: 0.24) // 1.2× the area: bigger, not big enough
        XCTAssertEqual(GazeTracker.pick(from: [a, b], following: nil), b, "nobody followed yet: the largest")
        XCTAssertEqual(GazeTracker.pick(from: [a, b], following: GazeTracker.head(of: a)), a)
        XCTAssertEqual(GazeTracker.pick(from: [b, a], following: GazeTracker.head(of: a)), a, "order doesn't matter")
    }

    func testPickSwitchesOnlyToAMuchBiggerBox() {
        XCTAssertEqual(GazeTracker.switchAreaRatio, 1.5)
        let a = person(x: 0.2)
        let following = GazeTracker.head(of: a)
        let justUnder = person(x: 0.8, width: 0.29) // 1.45×
        let over = person(x: 0.8, width: 0.31)      // 1.55×
        XCTAssertEqual(GazeTracker.pick(from: [a, justUnder], following: following), a)
        XCTAssertEqual(GazeTracker.pick(from: [a, over], following: following), over)
        XCTAssertNil(GazeTracker.pick(from: [.zero], following: following))
    }

    func testEyesStayWithThePersonTheyFollow() {
        var tracker = GazeTracker()
        let a = person(x: 0.2)
        feed(&tracker, [a], frames: 40, from: 0)
        XCTAssertEqual(tracker.gaze.x, 0.6, accuracy: 0.01)

        // Someone a little bigger walks in on the other side: the eyes don't leave.
        let passerBy = person(x: 0.8, width: 0.24)
        for i in 40..<80 {
            let gaze = tracker.update(people: [a, passerBy], at: t0 + Double(i) * frame)
            XCTAssertEqual(gaze.x, 0.6, accuracy: 0.01)
        }

        // Someone steps right up to the screen: now they take over.
        let upClose = person(x: 0.8, width: 0.4)
        let gaze = feed(&tracker, [a, upClose], frames: 40, from: 80)
        XCTAssertEqual(gaze.x, -0.6, accuracy: 0.01)

        // And the eyes stay with them, though the first person is still there.
        XCTAssertEqual(feed(&tracker, [a, upClose], frames: 10, from: 120).x, -0.6, accuracy: 0.01)
    }

    func testTwoSimilarPeopleCrossingDoNotSwapTheGaze() {
        // Same size, their order in Vision's list flipping every frame: the old "largest wins"
        // had nothing to choose by. The eyes stay on the one they started with.
        var tracker = GazeTracker()
        let a = person(x: 0.3)
        let b = person(x: 0.7)
        feed(&tracker, [a], frames: 40, from: 0)
        for i in 40..<100 {
            let gaze = tracker.update(people: i % 2 == 0 ? [a, b] : [b, a], at: t0 + Double(i) * frame)
            XCTAssertEqual(gaze.x, 0.4, accuracy: 0.01)
        }
    }

    // MARK: - Speed

    private func speed(from a: CGPoint, to b: CGPoint, over dt: TimeInterval) -> CGFloat {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() / CGFloat(dt)
    }

    func testGazeNeverMovesFasterThanTheCap() {
        XCTAssertEqual(GazeTracker.maxSpeed, 2.5)
        var tracker = GazeTracker()
        // Far corner to far corner: uncapped, the first step alone would cover ~0.66 in 0.1s.
        feed(&tracker, [person(x: 0.0, top: 1.0)], frames: 40, from: 0)
        XCTAssertEqual(tracker.gaze.x, 1, accuracy: 0.01)
        var previous = tracker.gaze
        var fastest: CGFloat = 0
        for i in 40..<80 {
            let gaze = tracker.update(people: [person(x: 1.0, top: 0.3, height: 0.3)], at: t0 + Double(i) * frame)
            fastest = max(fastest, speed(from: previous, to: gaze, over: frame))
            previous = gaze
        }
        XCTAssertLessThanOrEqual(fastest, GazeTracker.maxSpeed + 0.0001)
        XCTAssertEqual(fastest, GazeTracker.maxSpeed, accuracy: 0.0001, "this jump is big enough to hit the cap")
        XCTAssertEqual(previous.x, -1, accuracy: 0.01, "capped, not stopped")
    }

    func testTheCapHoldsAcrossUnevenFramesAndOnTheWayHome() {
        var tracker = GazeTracker()
        var now = t0
        var previous = tracker.gaze
        let gaps: [TimeInterval] = [0.016, 0.05, 0.2, 0.033, 0.4, 0.1]
        for i in 0..<120 {
            let dt = gaps[i % gaps.count]
            now += dt
            let people: [CGRect]
            switch i {
            case ..<40: people = [person(x: 0.0, top: 1.0)]
            case ..<80: people = [person(x: 1.0, top: 0.3, height: 0.3)]
            default: people = []
            }
            let gaze = tracker.update(people: people, at: now)
            XCTAssertLessThanOrEqual(speed(from: previous, to: gaze, over: dt), GazeTracker.maxSpeed + 0.0001, "frame \(i)")
            previous = gaze
        }
    }

    // MARK: - Walking in

    func testPersonWalkingInFromTheEdgeWithDroppedFrames() {
        // 15 fps. Someone walks in from the camera's left edge (the viewer's right) and stops
        // past the middle. Vision clips their box to the frame while they enter, and loses
        // them every fifth frame.
        let dt: TimeInterval = 1.0 / 15
        let width: CGFloat = 0.3
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var tracker = GazeTracker()
        var previous = tracker.gaze
        var directions: [CGFloat] = [] // sign of each real x move
        var yDirections: [CGFloat] = []
        var furthestRight: CGFloat = 0

        for i in 0..<150 {
            let centerX = min(-0.2 + 0.25 * CGFloat(Double(i) * dt), 0.7) // enters, walks 3.6s, stands
            let box = person(x: centerX, width: width).intersection(unit)
            let dropped = i % 5 == 4
            let people = dropped || box.isNull || box.width <= 0 ? [] : [box]
            let gaze = tracker.update(people: people, at: t0 + Double(i) * dt)

            XCTAssertLessThanOrEqual(speed(from: previous, to: gaze, over: dt), GazeTracker.maxSpeed + 0.0001, "frame \(i)")
            let dx = gaze.x - previous.x
            if abs(dx) > 1e-9 { directions.append(dx > 0 ? 1 : -1) }
            let dy = gaze.y - previous.y
            if abs(dy) > 1e-9 { yDirections.append(dy > 0 ? 1 : -1) }
            furthestRight = max(furthestRight, gaze.x)
            previous = gaze
        }

        func changes(_ signs: [CGFloat]) -> Int { zip(signs, signs.dropFirst()).filter { $0 != $1 }.count }
        // Out toward the edge they came in from, then back across with them. Nothing else:
        // a dropped frame must not send the eyes home and back.
        XCTAssertLessThanOrEqual(changes(directions), 1)
        XCTAssertEqual(changes(yDirections), 0)
        XCTAssertEqual(directions.first, 1, "first toward the edge they entered from")
        XCTAssertGreaterThan(furthestRight, 0.3, "the eyes really went out to meet them")
        XCTAssertEqual(previous.x, -0.4, accuracy: 0.01, "and ended on where they stand")
    }
}

final class GazeCameraPolicyTests: XCTestCase {

    private let ac = LidSleepPolicy.Power(onBattery: false, batteryPercent: 80)

    private func decide(
        enabled: Bool = true, hasEyes: Bool = true, locked: Bool = true, viewers: Int = 1,
        access: GazeCameraPolicy.Access = .authorized, power: LidSleepPolicy.Power? = nil,
        thermal: LidSleepPolicy.Thermal = .nominal, cutOff: Bool = false
    ) -> GazeCameraPolicy.Decision {
        GazeCameraPolicy.decide(
            enabled: enabled, hasEyes: hasEyes, locked: locked, viewers: viewers, access: access,
            power: power ?? ac, thermal: thermal, cutOffForBattery: cutOff
        )
    }

    func testRunsOnlyWithEverythingInPlace() {
        XCTAssertTrue(decide().run)
        XCTAssertFalse(decide(enabled: false).run)
        XCTAssertFalse(decide(hasEyes: false).run)
        XCTAssertFalse(decide(locked: false).run, "never a camera while you're at the Mac")
        XCTAssertFalse(decide(viewers: 0).run, "faded to black: nobody to watch")
    }

    func testNeverPromptsFromTheLockScreen() {
        XCTAssertFalse(decide(access: .notDetermined).run)
        XCTAssertFalse(decide(access: .denied).run)
    }

    func testHotMacRestsItsEyes() {
        XCTAssertTrue(decide(thermal: .fair).run)
        XCTAssertFalse(decide(thermal: .serious).run)
        XCTAssertFalse(decide(thermal: .critical).run)
    }

    func testBatteryFloorAndHysteresis() {
        let atFloor = decide(power: .init(onBattery: true, batteryPercent: 30))
        XCTAssertFalse(atFloor.run)
        XCTAssertTrue(atFloor.cutOffForBattery)
        XCTAssertTrue(decide(power: .init(onBattery: true, batteryPercent: 31)).run)
        XCTAssertFalse(decide(power: .init(onBattery: true, batteryPercent: 33), cutOff: true).run)
        XCTAssertTrue(decide(power: .init(onBattery: true, batteryPercent: 35), cutOff: true).run)
        XCTAssertTrue(decide(power: .init(onBattery: false, batteryPercent: 10), cutOff: true).run, "plugged in clears it")
    }
}
