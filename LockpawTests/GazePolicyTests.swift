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

    func testFirstFrameDoesNotJump() {
        var tracker = GazeTracker()
        XCTAssertEqual(tracker.update(people: [person(x: 0.1)], at: t0), .zero)
    }

    func testEasesTowardThePerson() {
        var tracker = GazeTracker()
        tracker.update(people: [person(x: 0.1)], at: t0)
        let step = tracker.update(people: [person(x: 0.1)], at: t0 + 0.1)
        XCTAssertGreaterThan(step.x, 0)
        XCTAssertLessThan(step.x, 0.8)
        var gaze = step
        for i in 2...30 { gaze = tracker.update(people: [person(x: 0.1)], at: t0 + Double(i) * 0.1) }
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
        tracker.update(people: [person(x: 0.1)], at: t0)
        let gaze = tracker.update(people: [person(x: 0.1)], at: t0 + 3600)
        XCTAssertLessThanOrEqual(gaze.x, 0.8)
    }

    func testResetLooksStraightAhead() {
        var tracker = GazeTracker()
        for i in 0...10 { tracker.update(people: [person(x: 0.1)], at: t0 + Double(i) * 0.1) }
        tracker.reset()
        XCTAssertEqual(tracker.gaze, .zero)
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
