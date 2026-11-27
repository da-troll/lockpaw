import XCTest
@testable import Lockpaw

final class LockScreenSizeTests: XCTestCase {

    private let laptop = CGSize(width: 1512, height: 982)
    private let ultrawide = CGSize(width: 3440, height: 1440)

    func testSmallIsTheDefaultAndChangesNothing() {
        XCTAssertEqual(LockScreenSize.defaultValue, .small)
        XCTAssertEqual(LockScreenSize.small.mascotScale, 1)
        XCTAssertEqual(LockScreenSize.small.textScale, 1)
        // The layout the lock screen had before sizes existed.
        for screen in [laptop, ultrawide] {
            let layout = LockScreenSize.small.mascotLayout(in: screen)
            let side = min(screen.width * 0.2, screen.height * 0.3)
            XCTAssertEqual(layout.side, side, accuracy: 0.0001)
            XCTAssertEqual(layout.topInset, screen.height * 0.32, accuracy: 0.0001)
            XCTAssertEqual(layout.unit, side * 0.12, accuracy: 0.0001)
        }
    }

    func testSizesAreOrderedAndDistinct() {
        let mascot = LockScreenSize.allCases.map(\.mascotScale)
        let text = LockScreenSize.allCases.map(\.textScale)
        XCTAssertEqual(LockScreenSize.allCases, [.small, .medium, .large])
        XCTAssertEqual(mascot, mascot.sorted())
        XCTAssertEqual(text, text.sorted())
        XCTAssertEqual(Set(mascot).count, 3)
        XCTAssertEqual(Set(text).count, 3)
    }

    func testResolution() {
        XCTAssertEqual(LockScreenSize.resolved(from: "small"), .small)
        XCTAssertEqual(LockScreenSize.resolved(from: "large"), .large)
        XCTAssertEqual(LockScreenSize.resolved(from: "medium"), .medium)
        XCTAssertEqual(LockScreenSize.resolved(from: "huge"), .small)
        XCTAssertEqual(LockScreenSize.resolved(from: nil), .small)
    }

    func testABiggerMascotGrowsUpwardNotJustDown() {
        for screen in [laptop, ultrawide] {
            let layouts = LockScreenSize.allCases.map { $0.mascotLayout(in: screen) }
            let centres = layouts.map { $0.topInset + $0.side / 2 }
            // Never lower than the Small mascot's centre, and each size starts higher up.
            XCTAssertLessThanOrEqual(centres[1], centres[0] + 0.0001)
            XCTAssertLessThanOrEqual(centres[2], centres[1] + 0.0001)
            XCTAssertLessThan(layouts[1].topInset, layouts[0].topInset)
            XCTAssertLessThan(layouts[2].topInset, layouts[1].topInset)
        }
    }

    func testSpacingUnderTheMascotDoesNotGrowWithIt() {
        let units = LockScreenSize.allCases.map { $0.mascotLayout(in: laptop).unit }
        XCTAssertEqual(units[0], units[1])
        XCTAssertEqual(units[2], units[1])
    }

    func testNoMascotReachesPastTwoThirdsOfTheScreen() {
        // Under the mascot the message, timer, rows and the 160pt unlock area still have
        // to fit, on a 14" laptop as much as on an ultrawide.
        for screen in [laptop, ultrawide] {
            for size in LockScreenSize.allCases {
                let layout = size.mascotLayout(in: screen)
                XCTAssertLessThanOrEqual(layout.topInset + layout.side, screen.height * 0.66 + 0.0001, "\(size)")
                XCTAssertGreaterThanOrEqual(layout.topInset, screen.height * 0.1 - 0.0001, "\(size)")
            }
        }
    }

    func testTopInsetHasAFloor() {
        // A very short, wide window: the mascot never rides up into the menu bar area.
        let squat = CGSize(width: 4000, height: 400)
        for size in LockScreenSize.allCases {
            XCTAssertGreaterThanOrEqual(size.mascotLayout(in: squat).topInset, 40 - 0.0001)
        }
    }
}
