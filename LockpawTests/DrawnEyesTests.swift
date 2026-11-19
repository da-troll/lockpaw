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

    // MARK: - Pupils in eyeballs

    /// Big white eyeballs with small dark pupils: the shape of most 3D-rendered mascots.
    private func googly(pupilRadius: Double = 5, eyeRadius: Double = 20) -> Canvas {
        var canvas = Canvas()
        canvas.pixels.luminance = [Float](repeating: 0.4, count: 256 * 256)
        canvas.disc(88, 110, radius: eyeRadius, 0.95)
        canvas.disc(168, 110, radius: eyeRadius, 0.95)
        canvas.disc(88, 110, radius: pupilRadius, 0.05)
        canvas.disc(168, 110, radius: pupilRadius, 0.05)
        return canvas
    }

    func testFindsSmallPupilsInBigEyeballs() throws {
        // 80 px apart and 10 px wide: eight pupil-widths, past the plain spacing limit.
        // Judged by the eyeballs they sit in (two eyeball-widths apart), they are eyes.
        let eyes = try find(googly()).get()
        XCTAssertEqual(eyes.left.center.x, 88.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.right.center.x, 168.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.left.center.y, 110.0 / 256, accuracy: 0.01)
    }

    func testPupilsInEyeballsBeatAMatchingPairElsewhere() throws {
        // Nostrils: as dark, as round and as level as the pupils. Before, a tie like this
        // was "ambiguous" and the image got no eyes at all.
        var canvas = googly(pupilRadius: 8)
        canvas.disc(112, 170, radius: 8, 0.05)
        canvas.disc(144, 170, radius: 8, 0.05)
        let eyes = try find(canvas).get()
        XCTAssertEqual(eyes.left.center.y, 110.0 / 256, accuracy: 0.01, "the pair inside eyeballs, not the nostrils")
    }

    func testTheGlintOnAPupilIsNotAnEye() throws {
        // A light dot inside each dark pupil is nested too, the other way round.
        var canvas = googly(pupilRadius: 10)
        canvas.disc(85, 107, radius: 2.5, 0.98)
        canvas.disc(165, 107, radius: 2.5, 0.98)
        let eyes = try find(canvas).get()
        XCTAssertEqual(eyes.left.center.x, 88.0 / 256, accuracy: 0.02, "centred on the pupil, not its glint")
    }

    func testTwoPairsOfBareSpotsAreStillAmbiguous() {
        // No eyeballs to tell them apart: the bonus must not turn a real tie into a guess.
        var canvas = Canvas()
        canvas.disc(96, 90, radius: 7, 0.15)
        canvas.disc(160, 90, radius: 7, 0.15)
        canvas.disc(96, 170, radius: 7, 0.15)
        canvas.disc(160, 170, radius: 7, 0.15)
        XCTAssertEqual(rejection(find(canvas)), .ambiguous)
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

    /// A robot's ear pads: dark, symmetric, level, and bigger than the eyes. Without the
    /// shape and spacing limits they tie with the eyes and make the image ambiguous.
    func testEarsAtTheSidesAreNotEyes() throws {
        var canvas = face()
        canvas.disc(36, 110, radius: 10, 0.15, ry: 27)
        canvas.disc(220, 110, radius: 10, 0.15, ry: 27)
        let eyes = try find(canvas).get()
        XCTAssertEqual(eyes.left.center.x, 96.0 / 256, accuracy: 0.01)
        XCTAssertEqual(eyes.right.center.x, 160.0 / 256, accuracy: 0.01)
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
