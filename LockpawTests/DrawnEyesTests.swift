import XCTest
@testable import Lockpaw

final class DrawnEyesTests: XCTestCase {

    /// A 256 px canvas: a mid-grey face, painted with discs and rings.
    private struct Canvas {
        var pixels = DrawnEyes.Pixels(
            width: 256, height: 256,
            luminance: [Float](repeating: 0.6, count: 256 * 256),
            opaque: [Bool](repeating: true, count: 256 * 256)
        )

        mutating func disc(_ cx: Double, _ cy: Double, radius: Double, _ value: Float, ry: Double? = nil) {
            paint { x, y in
                let dx = (x - cx) / radius, dy = (y - cy) / (ry ?? radius)
                return dx * dx + dy * dy <= 1 ? value : nil
            }
        }

        mutating func ring(_ cx: Double, _ cy: Double, radius: Double, thickness: Double, _ value: Float) {
            paint { x, y in
                let d = hypot(x - cx, y - cy)
                return abs(d - radius) <= thickness / 2 ? value : nil
            }
        }

        mutating func transparentOutside(radius: Double) {
            for y in 0..<256 { for x in 0..<256 where hypot(Double(x) - 128, Double(y) - 128) > radius {
                pixels.opaque[y * 256 + x] = false
                pixels.luminance[y * 256 + x] = 0
            } }
        }

        private mutating func paint(_ value: (Double, Double) -> Float?) {
            for y in 0..<256 { for x in 0..<256 {
                if let v = value(Double(x) + 0.5, Double(y) + 0.5) { pixels.luminance[y * 256 + x] = v }
            } }
        }
    }

    private func find(_ canvas: Canvas) -> Result<MascotEyes, EyeRejection> {
        DrawnEyes.find(in: canvas.pixels, revision: 301)
    }

    private func rejection(_ result: Result<MascotEyes, EyeRejection>) -> EyeRejection? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    /// Dark oval eyes and an "o" mouth: the shape of most drawn mascots.
    private func face() -> Canvas {
        var canvas = Canvas()
        canvas.disc(96, 110, radius: 7, 0.15, ry: 10)
        canvas.disc(160, 110, radius: 7, 0.15, ry: 10)
        canvas.ring(128, 160, radius: 9, thickness: 3, 0.15)
        return canvas
    }

    // MARK: - Finds

    func testFindsDarkEyesAndIgnoresTheMouth() throws {
        let eyes = try find(face()).get()
        XCTAssertEqual(eyes.left.center.x, 96.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.right.center.x, 160.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.left.center.y, 110.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.revision, 301)
    }

    func testTheOpeningIsBiggerThanThePupilSoItHasRoomToMove() throws {
        let eyes = try find(face()).get()
        XCTAssertGreaterThan(eyes.left.size.width * 256, 14 * 2)
        XCTAssertLessThanOrEqual(eyes.left.size.width * 256, 64 * DrawnEyes.maxOpeningWidth + 0.01)
    }

    func testFindsLightEyesOnADarkFace() throws {
        var canvas = Canvas()
        canvas.pixels.luminance = [Float](repeating: 0.2, count: 256 * 256)
        canvas.disc(90, 120, radius: 8, 0.9)
        canvas.disc(166, 120, radius: 8, 0.9)
        XCTAssertNoThrow(try find(canvas).get())
    }

    func testHighlightsInsideThePupilsDontConfuseIt() throws {
        var canvas = face()
        canvas.disc(98, 106, radius: 2, 0.95)
        canvas.disc(162, 106, radius: 2, 0.95)
        let eyes = try find(canvas).get()
        XCTAssertEqual(eyes.left.center.x, 96.0 / 256, accuracy: 0.02, "the pupils, not the glints")
    }

    func testATransparentBackgroundIsNotAnEdge() throws {
        var canvas = face()
        canvas.transparentOutside(radius: 110)
        XCTAssertNoThrow(try find(canvas).get())
    }

    func testDeterministic() {
        XCTAssertEqual(find(face()), find(face()))
    }

    // MARK: - Rejects

    func testAPlainImageHasNoEyes() {
        XCTAssertEqual(rejection(find(Canvas())), .noFace)
    }

    func testOneEyeIsNotAPair() {
        var canvas = Canvas()
        canvas.disc(96, 110, radius: 7, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .noFace)
    }

    func testMismatchedSpotsAreNotAPair() {
        var canvas = Canvas()
        canvas.disc(96, 110, radius: 4, 0.15)
        canvas.disc(160, 110, radius: 12, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .noFace)
    }

    func testTiltedSpotsAreNotAPair() {
        var canvas = Canvas()
        canvas.disc(96, 90, radius: 6, 0.15)
        canvas.disc(160, 140, radius: 6, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .noFace)
    }

    func testRingsAreNotEyes() {
        var canvas = Canvas()
        canvas.ring(96, 110, radius: 10, thickness: 2, 0.15)
        canvas.ring(160, 110, radius: 10, thickness: 2, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .noFace)
    }

    func testTwoFacesAreAmbiguous() {
        var canvas = Canvas()
        for (cx, cy) in [(50.0, 70.0), (100.0, 70.0), (156.0, 190.0), (206.0, 190.0)] {
            canvas.disc(cx, cy, radius: 6, 0.15)
        }
        XCTAssertEqual(rejection(find(canvas)), .ambiguous)
    }

    func testTinyEyesAreTooSmall() {
        var canvas = Canvas()
        canvas.disc(122, 110, radius: 3, 0.15)
        canvas.disc(134, 110, radius: 3, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .eyesTooSmall)
    }
}
