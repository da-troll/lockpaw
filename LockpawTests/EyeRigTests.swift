import XCTest
@testable import Lockpaw

final class EyeRigTests: XCTestCase {

    private typealias RGB = (UInt8, UInt8, UInt8)
    private static let face: RGB = (200, 160, 120)
    private static let outline: RGB = (60, 40, 30)
    private static let white: RGB = (240, 240, 245)
    private static let pupil: RGB = (30, 20, 20)

    private static let size = (width: 400, height: 300)
    private static let centers = [(x: 130.0, y: 140.0), (x: 270.0, y: 140.0)]

    /// A drawn face: two round eyes (dark outline, white, dark pupil with a highlight).
    private func canvas(eyeRadius: Double? = 40, pupilRadius: Double = 16, highlight: Bool = true) -> EyeRig.Bitmap {
        var bitmap = EyeRig.Bitmap(width: Self.size.width, height: Self.size.height)
        func disc(_ cx: Double, _ cy: Double, _ radius: Double, _ color: RGB) {
            for y in 0..<bitmap.height { for x in 0..<bitmap.width
            where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) <= radius {
                let o = (y * bitmap.width + x) * 4
                bitmap.rgba[o] = color.0; bitmap.rgba[o + 1] = color.1; bitmap.rgba[o + 2] = color.2
            } }
        }
        for i in 0..<(bitmap.width * bitmap.height) {
            bitmap.rgba[i * 4] = Self.face.0; bitmap.rgba[i * 4 + 1] = Self.face.1
            bitmap.rgba[i * 4 + 2] = Self.face.2; bitmap.rgba[i * 4 + 3] = 255
        }
        for c in Self.centers {
            if let eyeRadius {
                disc(c.x, c.y, eyeRadius + 4, Self.outline)
                disc(c.x, c.y, eyeRadius, Self.white)
            }
            disc(c.x, c.y, pupilRadius, Self.pupil)
            if highlight { disc(c.x - 5, c.y - 5, 3, Self.white) }
        }
        return bitmap
    }

    /// What the detector would hand over: pupil centres, and an area ~2.4 pupils across.
    private func eyes(pupilRadius: Double = 16) -> MascotEyes {
        func eye(_ c: (x: Double, y: Double)) -> MascotEyes.Eye {
            MascotEyes.Eye(
                center: CGPoint(x: c.x / Double(Self.size.width), y: c.y / Double(Self.size.height)),
                size: CGSize(width: pupilRadius * 4.8 / Double(Self.size.width), height: pupilRadius * 4.8 / Double(Self.size.height))
            )
        }
        return MascotEyes(left: eye(Self.centers[0]), right: eye(Self.centers[1]), revision: 1)
    }

    private func build(_ bitmap: EyeRig.Bitmap, pupilRadius: Double = 16) throws -> EyeRig.Layers {
        try EyeRig.build(image: bitmap, eyes: eyes(pupilRadius: pupilRadius)).get()
    }

    private func rejection(_ result: Result<EyeRig.Layers, EyeRejection>) -> EyeRejection? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    /// The layers' origin in image pixels.
    private func origin(_ layers: EyeRig.Layers) -> (x: Int, y: Int) {
        (Int((layers.info.rect.minX * CGFloat(Self.size.width)).rounded()),
         Int((layers.info.rect.minY * CGFloat(Self.size.height)).rounded()))
    }

    private func pixel(_ bitmap: EyeRig.Bitmap, _ x: Int, _ y: Int) -> [Int] {
        let o = (y * bitmap.width + x) * 4
        return (0..<4).map { Int(bitmap.rgba[o + $0]) }
    }

    /// A layer's pixel at image coordinates.
    /// Beyond the layer's edge there is nothing: transparent.
    private func pixel(_ layer: EyeRig.Bitmap, of layers: EyeRig.Layers, imageX: Int, imageY: Int) -> [Int] {
        let o = origin(layers)
        let x = imageX - o.x, y = imageY - o.y
        guard x >= 0, y >= 0, x < layer.width, y < layer.height else { return [0, 0, 0, 0] }
        return pixel(layer, x, y)
    }

    /// The mascot as it is drawn: the image, the plate over it, then the pupils, moved and clipped.
    private func composite(_ base: EyeRig.Bitmap, _ layers: EyeRig.Layers, gaze: CGPoint) -> EyeRig.Bitmap {
        var out = base
        let o = origin(layers)
        let shift = EyeRig.offset(gaze: gaze, travel: layers.info.travel,
                                  fittedSize: CGSize(width: base.width, height: base.height))
        let sx = Int(shift.width.rounded()), sy = Int(shift.height.rounded())
        let w = layers.plate.width, h = layers.plate.height
        for y in 0..<h { for x in 0..<w {
            let target = ((o.y + y) * base.width + o.x + x) * 4, i = (y * w + x) * 4
            let plateAlpha = Float(layers.plate.rgba[i + 3]) / 255
            for c in 0..<3 {
                out.rgba[target + c] = UInt8(Float(layers.plate.rgba[i + c]) * plateAlpha + Float(out.rgba[target + c]) * (1 - plateAlpha))
            }
            let px = x - sx, py = y - sy
            guard px >= 0, py >= 0, px < w, py < h else { continue }
            let s = (py * w + px) * 4
            let alpha = Float(layers.pupils.rgba[s + 3]) / 255 * Float(layers.clip.rgba[i + 3]) / 255
            for c in 0..<3 {
                out.rgba[target + c] = UInt8(Float(layers.pupils.rgba[s + c]) * alpha + Float(out.rgba[target + c]) * (1 - alpha))
            }
        } }
        return out
    }

    private func isDark(_ p: [Int]) -> Bool { p[0] < 90 && p[1] < 90 && p[2] < 90 }
    private func isWhite(_ p: [Int]) -> Bool { p[0] > 200 && p[1] > 200 && p[2] > 200 }

    // MARK: - Layers

    func testCutsThePupilOutAndPaintsTheEyeInUnderIt() throws {
        let layers = try build(canvas())
        for c in Self.centers {
            let x = Int(c.x), y = Int(c.y)
            let plate = pixel(layers.plate, of: layers, imageX: x, imageY: y)
            XCTAssertEqual(plate[3], 255, "the plate covers where the pupil was")
            XCTAssertTrue(isWhite(plate), "and is the colour of the eye, not the pupil: \(plate)")

            let sprite = pixel(layers.pupils, of: layers, imageX: x + 8, imageY: y + 4)
            XCTAssertEqual(sprite[3], 255)
            XCTAssertTrue(isDark(sprite), "the pupil's own pixels are on the moving layer: \(sprite)")
        }
    }

    func testTheHighlightTravelsWithThePupil() throws {
        let layers = try build(canvas())
        let c = Self.centers[0]
        let glint = pixel(layers.pupils, of: layers, imageX: Int(c.x) - 5, imageY: Int(c.y) - 5)
        XCTAssertEqual(glint[3], 255)
        XCTAssertTrue(isWhite(glint), "\(glint)")
    }

    func testThePlateIsOnlyThereUnderThePupils() throws {
        let layers = try build(canvas())
        let c = Self.centers[0]
        // On the eye white well clear of the pupil, and on the layer's own corner.
        XCTAssertEqual(pixel(layers.plate, of: layers, imageX: Int(c.x) + 32, imageY: Int(c.y))[3], 0)
        XCTAssertEqual(pixel(layers.plate, 0, 0)[3], 0)
        XCTAssertEqual(pixel(layers.pupils, of: layers, imageX: Int(c.x) + 32, imageY: Int(c.y))[3], 0)
    }

    func testTheClipIsTheEyeAndNothingAroundIt() throws {
        let layers = try build(canvas())
        let c = Self.centers[1]
        let x = Int(c.x), y = Int(c.y)
        XCTAssertEqual(pixel(layers.clip, of: layers, imageX: x, imageY: y)[3], 255)
        XCTAssertEqual(pixel(layers.clip, of: layers, imageX: x + 30, imageY: y)[3], 255, "eye white")
        XCTAssertEqual(pixel(layers.clip, of: layers, imageX: x, imageY: y - 30)[3], 255, "eye white")
        // The outline is 40...44 px out. The layers stop within a couple of pixels of the eye,
        // so anything further out is simply not on them.
        let o = origin(layers)
        XCTAssertGreaterThan(o.x, Int(Self.centers[0].x) - 48)
        XCTAssertLessThan(o.x + layers.clip.width, Int(c.x) + 48)
        XCTAssertEqual(pixel(layers.clip, of: layers, imageX: x + 43, imageY: y)[3], 0, "the outline is not eye")
    }

    func testLayersCoverBothEyesInOneRect() throws {
        let layers = try build(canvas())
        let rect = layers.info.rect
        XCTAssertEqual(layers.info.version, EyeRig.version)
        XCTAssertEqual(layers.plate.width, layers.pupils.width)
        XCTAssertEqual(layers.plate.height, layers.clip.height)
        for c in Self.centers {
            XCTAssertTrue(rect.contains(CGPoint(x: c.x / 400, y: c.y / 300)))
        }
        XCTAssertLessThan(rect.width, 0.65, "just the eyes, not the face")
        XCTAssertLessThan(rect.height, 0.4)
    }

    // MARK: - On screen

    func testLookingStraightAheadIsTheOriginalImage() throws {
        let base = canvas()
        let layers = try build(base)
        let drawn = composite(base, layers, gaze: .zero)
        var worst = 0
        for i in 0..<base.rgba.count { worst = max(worst, abs(Int(base.rgba[i]) - Int(drawn.rgba[i]))) }
        XCTAssertLessThanOrEqual(worst, 6, "cutting the pupil out and putting it back changes nothing visible")
    }

    func testOnlyThePupilMovesAndNothingOutsideTheEyeChanges() throws {
        let base = canvas()
        let layers = try build(base)
        let drawn = composite(base, layers, gaze: CGPoint(x: 1, y: 0))
        let shift = Int((layers.info.travel.right * 400).rounded())
        XCTAssertGreaterThan(shift, 8)

        for c in Self.centers {
            let x = Int(c.x), y = Int(c.y)
            XCTAssertTrue(isWhite(pixel(drawn, x - 12, y + 6)), "where the pupil was is eye white now")
            XCTAssertTrue(isDark(pixel(drawn, x + shift + 8, y + 6)), "and the pupil is further right")
        }

        // The old renderer's fault was a doubled rim: pixels outside the eye that moved.
        // Here every pixel the clip doesn't cover is the original, exactly.
        let o = origin(layers)
        var changedOutside = 0
        for y in 0..<base.height { for x in 0..<base.width {
            let lx = x - o.x, ly = y - o.y
            let inClip = lx >= 0 && ly >= 0 && lx < layers.clip.width && ly < layers.clip.height
                && layers.clip.rgba[(ly * layers.clip.width + lx) * 4 + 3] > 0
            if !inClip, pixel(drawn, x, y) != pixel(base, x, y) { changedOutside += 1 }
        } }
        XCTAssertEqual(changedOutside, 0)
    }

    func testThePupilNeverLeavesTheEye() throws {
        let base = canvas()
        let layers = try build(base)
        for gaze in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1), CGPoint(x: 5, y: 5)] {
            let drawn = composite(base, layers, gaze: gaze)
            for c in Self.centers {
                // Dark pixels beyond the eye white (radius 40) other than the outline ring: none.
                for y in 0..<base.height { for x in 0..<base.width {
                    let d = hypot(Double(x) + 0.5 - c.x, Double(y) + 0.5 - c.y)
                    if d > 45, d < 60 { XCTAssertEqual(pixel(drawn, x, y), pixel(base, x, y)) }
                    if d > 37, d < 39.5 { XCTAssertTrue(isWhite(pixel(drawn, x, y)), "a rim of white always shows: \(gaze)") }
                } }
            }
        }
    }

    // MARK: - Travel

    func testTravelIsTheRoomInTheEye() throws {
        // Pupil radius 16 in an eye of radius 40: 24 px of room, less the margin, but never
        // more than half the pupil's width sideways or 0.4 of its height up and down.
        let travel = try build(canvas()).info.travel
        for sideways in [travel.left, travel.right] {
            XCTAssertGreaterThanOrEqual(sideways * 400, 12)
            XCTAssertLessThanOrEqual(sideways * 400, 17)
        }
        for vertical in [travel.up, travel.down] {
            XCTAssertGreaterThanOrEqual(vertical * 300, 9)
            XCTAssertLessThanOrEqual(vertical * 300, 14)
        }
    }

    func testABigPupilInASmallEyeGetsLessTravel() throws {
        let roomy = try build(canvas()).info.travel
        let tight = try build(canvas(pupilRadius: 30), pupilRadius: 30).info.travel
        XCTAssertLessThan(tight.right, roomy.right)
        XCTAssertLessThanOrEqual(tight.right * 400, 8)
    }

    func testAPupilThatFillsTheEyeHasNoRoom() {
        // 3 px of white around the pupil: nowhere to go, and too little to learn the eye's
        // colour from. It must not come back as eyes that slide over the outline.
        let result = EyeRig.build(image: canvas(pupilRadius: 37), eyes: eyes(pupilRadius: 37))
        XCTAssertEqual(rejection(result), .noRoomToMove)
    }

    func testOtsuSplitsAtTheEdgeOfTheDarkerBin() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[20] = 100
        histogram[43] = 100
        histogram[200] = 400
        // 43.x is dark: the threshold has to sit above the whole of bin 43.
        XCTAssertEqual(EyeRig.otsu(histogram), 44)
        XCTAssertNil(EyeRig.otsu([Int](repeating: 0, count: 256)))
        var flat = [Int](repeating: 0, count: 256)
        flat[120] = 50
        XCTAssertNil(EyeRig.otsu(flat), "one tone has no split")
    }

    func testDotEyesOnAFlatFaceAreCappedByThePupilsSize() throws {
        // No eye white at all: the "eye" is the face, so the cap is what limits travel.
        let layers = try build(canvas(eyeRadius: nil, highlight: false))
        XCTAssertEqual(layers.info.travel.right * 400, 32 * EyeRig.maxTravel.width, accuracy: 1.5)
        XCTAssertEqual(layers.info.travel.down * 300, 32 * EyeRig.maxTravel.height, accuracy: 1.5)
        let plate = pixel(layers.plate, of: layers, imageX: 130, imageY: 140)
        XCTAssertEqual(Array(plate[0..<3]), [200, 160, 120], "painted in with the face's colour")
    }

    // MARK: - Rejections

    func testAFlatPatchIsNotAnEye() {
        var blank = EyeRig.Bitmap(width: 400, height: 300)
        for i in 0..<(400 * 300) { blank.rgba[i * 4] = 120; blank.rgba[i * 4 + 1] = 120; blank.rgba[i * 4 + 2] = 120; blank.rgba[i * 4 + 3] = 255 }
        XCTAssertEqual(rejection(EyeRig.build(image: blank, eyes: eyes())), .cannotSeparate)
    }

    func testAPupilThatRunsOffIntoTheFaceIsRejected() {
        // The "pupil" is the same dark as a band running out of the window: not a blob.
        var smeared = canvas(eyeRadius: nil, highlight: false)
        for y in 132..<148 { for x in 0..<400 {
            let o = (y * 400 + x) * 4
            smeared.rgba[o] = 30; smeared.rgba[o + 1] = 20; smeared.rgba[o + 2] = 20
        } }
        XCTAssertEqual(rejection(EyeRig.build(image: smeared, eyes: eyes())), .cannotSeparate)
    }

    func testBadInputIsRejectedNotCrashedOn() {
        XCTAssertEqual(rejection(EyeRig.build(image: EyeRig.Bitmap(width: 4, height: 4), eyes: eyes())), .cannotSeparate)
        let lying = EyeRig.Bitmap(width: 400, height: 300, rgba: [0, 0, 0, 255])
        XCTAssertEqual(rejection(EyeRig.build(image: lying, eyes: eyes())), .cannotSeparate)
        let sameSpot = MascotEyes(left: eyes().left, right: eyes().left, revision: 1)
        XCTAssertEqual(rejection(EyeRig.build(image: canvas(), eyes: sameSpot)), .cannotSeparate)
    }

    func testDeterministic() throws {
        XCTAssertEqual(try build(canvas()), try build(canvas()))
    }

    // MARK: - Gaze to offset

    private let travel = EyeRig.Travel(left: 0.02, right: 0.04, up: 0.01, down: 0.03)
    private let fitted = CGSize(width: 500, height: 400)

    func testOffsetUsesTheRoomOnTheSideLookedAt() {
        XCTAssertEqual(EyeRig.offset(gaze: .zero, travel: travel, fittedSize: fitted), .zero)
        XCTAssertEqual(EyeRig.offset(gaze: CGPoint(x: 1, y: 0), travel: travel, fittedSize: fitted).width, 20, accuracy: 0.0001)
        XCTAssertEqual(EyeRig.offset(gaze: CGPoint(x: -1, y: 0), travel: travel, fittedSize: fitted).width, -10, accuracy: 0.0001)
        XCTAssertEqual(EyeRig.offset(gaze: CGPoint(x: 0, y: 1), travel: travel, fittedSize: fitted).height, 12, accuracy: 0.0001)
        XCTAssertEqual(EyeRig.offset(gaze: CGPoint(x: 0, y: -0.5), travel: travel, fittedSize: fitted).height, -2, accuracy: 0.0001)
    }

    func testOffsetNeverExceedsTheTravel() {
        let far = EyeRig.offset(gaze: CGPoint(x: 9, y: 0), travel: travel, fittedSize: fitted)
        XCTAssertEqual(far.width, 20, accuracy: 0.0001)
    }

    func testDiagonalGazeIsHeldToTheCircle() {
        // A round eye has less room on the diagonal than straight across.
        let corner = EyeRig.offset(gaze: CGPoint(x: 1, y: 1), travel: travel, fittedSize: fitted)
        XCTAssertEqual(corner.width, 20 * 0.5.squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(corner.height, 12 * 0.5.squareRoot(), accuracy: 0.0001)
    }

    // MARK: - Stored layers

    func testLayersSurviveTheirPNG() throws {
        let layers = try build(canvas())
        let png = try XCTUnwrap(EyeRigImages.atlasPNG(for: layers))
        let rig = try XCTUnwrap(EyeRigImages.rig(fromAtlas: png, info: layers.info))
        XCTAssertEqual(rig.info, layers.info)
        for image in [rig.plate, rig.pupils, rig.clip] {
            XCTAssertEqual(image.width, layers.plate.width)
            XCTAssertEqual(image.height, layers.plate.height)
        }
        // Read back, each layer is the one that went in (to within premultiplied rounding).
        for (image, original) in [(rig.plate, layers.plate), (rig.pupils, layers.pupils), (rig.clip, layers.clip)] {
            let back = try XCTUnwrap(EyeRig.Bitmap(image))
            var worst = 0
            for i in 0..<(original.width * original.height) where original.rgba[i * 4 + 3] == 255 {
                for c in 0..<4 { worst = max(worst, abs(Int(back.rgba[i * 4 + c]) - Int(original.rgba[i * 4 + c]))) }
            }
            XCTAssertLessThanOrEqual(worst, 2)
        }
        XCTAssertLessThan(png.count, 20_000, "mostly transparent, so small on disk")
    }

    func testAnUnreadableAtlasIsNoRig() throws {
        let info = try build(canvas()).info
        XCTAssertNil(EyeRigImages.rig(fromAtlas: Data([1, 2, 3]), info: info))
    }
}
