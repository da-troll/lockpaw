import XCTest
@testable import Lockpaw

final class MascotEyesTests: XCTestCase {

    private let image = CGSize(width: 1000, height: 1000)

    /// A straight-on face filling the middle of the image, pupils 160 px apart.
    private func face(
        bounds: CGRect = CGRect(x: 300, y: 250, width: 400, height: 450),
        confidence: Float = 0.95,
        yaw: Double? = 0,
        left: CGPoint? = CGPoint(x: 420, y: 420),
        right: CGPoint? = CGPoint(x: 580, y: 420),
        leftBox: CGRect? = CGRect(x: 380, y: 405, width: 80, height: 30),
        rightBox: CGRect? = CGRect(x: 540, y: 405, width: 80, height: 30)
    ) -> FaceCandidate {
        FaceCandidate(bounds: bounds, confidence: confidence, yaw: yaw,
                      leftPupil: left, rightPupil: right, leftEyeBox: leftBox, rightEyeBox: rightBox)
    }

    private func evaluate(_ faces: [FaceCandidate], size: CGSize? = nil) -> Result<MascotEyes, EyeRejection> {
        EyeDetectionPolicy.evaluate(faces, imageSize: size ?? image, revision: 3)
    }

    private func rejection(_ result: Result<MascotEyes, EyeRejection>) -> EyeRejection? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    // MARK: - Accepts

    func testAcceptsOneClearFace() throws {
        let eyes = try evaluate([face()]).get()
        XCTAssertEqual(eyes.left.center.x, 0.42, accuracy: 0.0001)
        XCTAssertEqual(eyes.right.center.x, 0.58, accuracy: 0.0001)
        XCTAssertEqual(eyes.left.center.y, 0.42, accuracy: 0.0001)
        // 80 px contour over 160 px pupil distance = 0.5, inside the limits: kept as found.
        XCTAssertEqual(eyes.left.size.width, 0.08, accuracy: 0.0001)
        XCTAssertEqual(eyes.revision, 3)
    }

    func testLeftIsAlwaysTheViewersLeft() throws {
        let eyes = try evaluate([face(left: CGPoint(x: 580, y: 420), right: CGPoint(x: 420, y: 420),
                                      leftBox: CGRect(x: 540, y: 405, width: 80, height: 30),
                                      rightBox: CGRect(x: 380, y: 405, width: 60, height: 30))]).get()
        XCTAssertLessThan(eyes.left.center.x, eyes.right.center.x)
        // The box travels with its pupil.
        XCTAssertEqual(eyes.left.size.width, 0.06, accuracy: 0.0001)
    }

    func testIgnoresASmallFaceInTheBackground() {
        let background = face(bounds: CGRect(x: 20, y: 20, width: 80, height: 90))
        XCTAssertNoThrow(try evaluate([face(), background]).get())
    }

    func testEyeOpeningIsClampedToSaneProportions() throws {
        let sloppy = face(leftBox: CGRect(x: 300, y: 300, width: 400, height: 200), rightBox: nil)
        let eyes = try evaluate([sloppy]).get()
        // Clamped to 0.6 × 160 px wide and 0.35 × 160 px tall.
        XCTAssertEqual(eyes.left.size.width, 0.096, accuracy: 0.0001)
        XCTAssertEqual(eyes.left.size.height, 0.056, accuracy: 0.0001)
        // No contour: the fallback proportions.
        XCTAssertEqual(eyes.right.size.width, 0.42 * 0.16, accuracy: 0.0001)
    }

    func testDeterministic() {
        XCTAssertEqual(evaluate([face()]), evaluate([face()]))
    }

    func testRoundTripsThroughJSON() throws {
        let eyes = try evaluate([face()]).get()
        let decoded = try JSONDecoder().decode(MascotEyes.self, from: JSONEncoder().encode(eyes))
        XCTAssertEqual(decoded, eyes)
    }

    // MARK: - Rejects

    func testRejectsNoFace() {
        XCTAssertEqual(rejection(evaluate([])), .noFace)
        XCTAssertEqual(rejection(evaluate([face()], size: .zero)), .noFace)
    }

    func testRejectsTwoFacesOfSimilarSize() {
        let second = face(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(rejection(evaluate([face(), second])), .multipleFaces)
    }

    func testRejectsALowConfidenceFace() {
        XCTAssertEqual(rejection(evaluate([face(confidence: 0.4)])), .unsure)
    }

    func testRejectsAMissingPupil() {
        XCTAssertEqual(rejection(evaluate([face(right: nil)])), .eyesNotFound)
    }

    func testRejectsEyesTooSmallToMove() {
        // 160 px apart is 8% of a 2000 px image: under the 12% floor.
        XCTAssertEqual(rejection(evaluate([face()], size: CGSize(width: 2000, height: 2000))), .eyesTooSmall)
    }

    func testRejectsATurnedHead() {
        XCTAssertEqual(rejection(evaluate([face(yaw: 0.8)])), .turnedOrTilted)
        XCTAssertNoThrow(try evaluate([face(yaw: nil)]).get(), "no yaw reported is not a rejection")
    }

    func testRejectsATiltedHead() {
        XCTAssertEqual(rejection(evaluate([face(right: CGPoint(x: 580, y: 480))])), .turnedOrTilted)
    }

    func testRejectsPupilsThatDontFitTheFace() {
        // 160 px apart on a 900 px wide face: 18%, nobody's eyes are that close.
        let wide = face(bounds: CGRect(x: 50, y: 250, width: 900, height: 450))
        XCTAssertEqual(rejection(evaluate([wide])), .implausible)
    }

    func testRejectsPupilsOutsideTheFace() {
        let offFace = face(bounds: CGRect(x: 300, y: 500, width: 400, height: 450))
        XCTAssertEqual(rejection(evaluate([offFace])), .implausible)
    }

    // MARK: - Layout

    func testFittedRectLetterboxesAWideImage() {
        let rect = EyeLayout.fittedRect(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect, CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    func testFittedRectHandlesNothingToFit() {
        XCTAssertEqual(EyeLayout.fittedRect(imageSize: .zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testEyeRectScalesWithTheFittedImage() {
        let eye = MascotEyes.Eye(center: CGPoint(x: 0.5, y: 0.25), size: CGSize(width: 0.2, height: 0.1))
        XCTAssertEqual(EyeLayout.eyeRect(eye, fittedSize: CGSize(width: 200, height: 400)),
                       CGRect(x: 80, y: 80, width: 40, height: 40))
    }

    func testPupilOffsetIsSmallAndClamped() {
        let eye = MascotEyes.Eye(center: .zero, size: CGSize(width: 0.1, height: 0.05))
        let eyes = MascotEyes(left: eye, right: eye, revision: 3)
        let full = EyeLayout.pupilOffset(gaze: CGPoint(x: 5, y: -5), eyes: eyes, fittedSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(full.width, 100 * MascotEyes.travelFraction.width, accuracy: 0.0001)
        XCTAssertEqual(full.height, -50 * MascotEyes.travelFraction.height, accuracy: 0.0001)
    }
}

final class MascotEyesRecordTests: XCTestCase {
    func testRecordsARejectionAndRoundTrips() throws {
        let record = MascotEyesRecord(revision: 3, result: .failure(.multipleFaces))
        XCTAssertNil(record.eyes)
        let decoded = try JSONDecoder().decode(MascotEyesRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.rejection, .multipleFaces)
    }
}
