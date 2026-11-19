import XCTest
import AppKit
@testable import Lockpaw

@MainActor
final class CustomMascotTests: XCTestCase {
    private var directory: URL!
    private var store: CustomMascot!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CustomMascotTests-\(UUID().uuidString)", isDirectory: true)
        store = CustomMascot(directory: directory, findEyes: { _ in .failure(.noFace) }, eyesRevision: 3)
    }

    private static let sampleEyes = MascotEyes(
        left: .init(center: CGPoint(x: 0.4, y: 0.4), size: CGSize(width: 0.08, height: 0.03)),
        right: .init(center: CGPoint(x: 0.6, y: 0.4), size: CGSize(width: 0.08, height: 0.03)),
        revision: 3
    )

    private static let sampleRigInfo = EyeRig.Info(
        version: 1,
        rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
        travel: .init(left: 0.02, right: 0.02, up: 0.01, down: 0.01)
    )

    /// Stand-in layers: the store only has to keep them and hand them back.
    private static var sampleLayers: EyeRig.Layers {
        let layer = EyeRig.Bitmap(width: 8, height: 4, rgba: [UInt8](repeating: 200, count: 8 * 4 * 4))
        return EyeRig.Layers(plate: layer, pupils: layer, clip: layer, info: sampleRigInfo)
    }

    private func makeStore(
        finding result: Result<MascotEyes, EyeRejection>,
        rig: Result<EyeRig.Layers, EyeRejection>? = nil,
        revision: Int = 3
    ) -> CustomMascot {
        let rig = rig ?? .success(Self.sampleLayers)
        return CustomMascot(directory: directory, findEyes: { _ in result }, buildRig: { _, _ in rig }, eyesRevision: revision)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Empty state

    func testNothingInstalledInitially() {
        XCTAssertFalse(store.hasImage)
        XCTAssertNil(store.loadImage())
    }

    // MARK: - Install

    func testInstallCopiesTheImageIntoTheStore() throws {
        try store.install(from: makeImageFile(pixels: 24))

        XCTAssertTrue(store.hasImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL.path))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 24, height: 24))
    }

    func testInstallCreatesTheDirectoryWhenMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.install(from: makeImageFile(pixels: 8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInstallReplacesAPreviousImage() throws {
        try store.install(from: makeImageFile(pixels: 10))
        try store.install(from: makeImageFile(pixels: 30))

        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 30, height: 30))
    }

    /// Validation happens before the write, so a junk file can never wipe a working mascot.
    func testInstallRejectsAFileThatIsNotAnImage() throws {
        let junk = directory.appendingPathComponent("junk.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("definitely not an image".utf8).write(to: junk)

        XCTAssertThrowsError(try store.install(from: junk))
        XCTAssertFalse(store.hasImage)
    }

    func testARejectedInstallLeavesTheExistingImageIntact() throws {
        try store.install(from: makeImageFile(pixels: 16))

        let junk = directory.appendingPathComponent("junk.png")
        try Data("definitely not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try store.install(from: junk))

        XCTAssertTrue(store.hasImage)
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 16, height: 16))
    }

    func testInstallThrowsWhenTheSourceDoesNotExist() {
        let missing = directory.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try store.install(from: missing))
        XCTAssertFalse(store.hasImage)
    }

    // MARK: - Downsampling (a photo must not sit decoded at full size for hours)

    func testInstallDownsamplesToTheMaximumEdge() throws {
        try store.install(from: makeImageFile(pixels: CustomMascot.maxPixelSize * 3))

        let size = try XCTUnwrap(store.loadImage()?.size)
        XCTAssertEqual(max(size.width, size.height), CGFloat(CustomMascot.maxPixelSize))
    }

    func testInstallNeverUpscalesASmallImage() throws {
        try store.install(from: makeImageFile(pixels: 24))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 24, height: 24))
    }

    // MARK: - hasImage is cached, so it must be seeded from disk

    func testHasImageIsSeededFromDiskForANewStore() throws {
        try store.install(from: makeImageFile(pixels: 8))

        let fresh = CustomMascot(directory: directory)
        XCTAssertTrue(fresh.hasImage)
        XCTAssertTrue(fresh.canShow(.custom))
    }

    // MARK: - Remove

    func testRemoveDeletesTheImage() throws {
        try store.install(from: makeImageFile(pixels: 12))
        store.remove()

        XCTAssertFalse(store.hasImage)
        XCTAssertNil(store.loadImage())
    }

    func testRemoveOnAnEmptyStoreIsHarmless() {
        store.remove()
        XCTAssertFalse(store.hasImage)
    }

    // MARK: - Revision (what makes SwiftUI re-read the file)

    func testRevisionAdvancesOnInstallAndRemove() throws {
        let start = store.revision

        try store.install(from: makeImageFile(pixels: 8))
        let afterInstall = store.revision
        XCTAssertGreaterThan(afterInstall, start)

        store.remove()
        XCTAssertGreaterThan(store.revision, afterInstall)
    }

    func testRevisionDoesNotAdvanceOnARejectedInstall() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = directory.appendingPathComponent("junk.png")
        try Data("nope".utf8).write(to: junk)

        let start = store.revision
        XCTAssertThrowsError(try store.install(from: junk))
        XCTAssertEqual(store.revision, start)
    }

    /// The cache must not outlive the file it came from, or Settings would keep
    /// showing the old mascot after a replace.
    func testLoadImageReflectsAReplacementAfterCaching() throws {
        try store.install(from: makeImageFile(pixels: 10))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 10, height: 10))

        try store.install(from: makeImageFile(pixels: 40))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 40, height: 40))
    }

    // MARK: - What the views gate on

    /// The "render nothing, never fall back to Dog" rule.
    func testCanShowFollowsTheInstalledImage() throws {
        XCTAssertTrue(store.canShow(.dog))
        XCTAssertTrue(store.canShow(.cat))
        XCTAssertFalse(store.canShow(.hidden))
        XCTAssertFalse(store.canShow(.custom))

        try store.install(from: makeImageFile(pixels: 8))
        XCTAssertTrue(store.canShow(.custom))

        store.remove()
        XCTAssertFalse(store.canShow(.custom))
    }

    // MARK: - Helpers

    private func makeImageFile(pixels: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let data = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))

        let sources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CustomMascotSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appendingPathComponent("source.png")
        try data.write(to: url)
        return url
    }

    // MARK: - Eyes (found once at install, kept next to the image)

    func testInstallFindsAndStoresTheEyes() throws {
        let eyed = makeStore(finding: .success(Self.sampleEyes))
        try eyed.install(from: makeImageFile(pixels: 16))

        XCTAssertEqual(eyed.eyes, Self.sampleEyes)
        XCTAssertNil(eyed.eyeRejection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eyed.eyesURL.path))
        XCTAssertEqual(makeStore(finding: .failure(.noFace)).eyes, Self.sampleEyes, "a new store reads the record, it doesn't re-detect")
    }

    func testAnImageWithoutEyesStillInstalls() throws {
        let eyed = makeStore(finding: .failure(.multipleFaces))
        try eyed.install(from: makeImageFile(pixels: 16))

        XCTAssertTrue(eyed.hasImage)
        XCTAssertNil(eyed.eyes)
        XCTAssertEqual(eyed.eyeRejection, .multipleFaces)
    }

    func testAnOlderDetectorsRecordIsIgnored() throws {
        try makeStore(finding: .success(Self.sampleEyes), revision: 2).install(from: makeImageFile(pixels: 16))

        let newer = makeStore(finding: .failure(.noFace), revision: 3)
        XCTAssertNil(newer.eyes)
        XCTAssertNil(newer.eyeRejection)
        newer.refreshEyesIfNeeded()
        XCTAssertEqual(newer.eyeRejection, .noFace)
    }

    func testRemoveForgetsTheEyes() throws {
        let eyed = makeStore(finding: .success(Self.sampleEyes))
        try eyed.install(from: makeImageFile(pixels: 16))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eyed.rigURL.path))
        eyed.remove()

        XCTAssertNil(eyed.eyes)
        XCTAssertNil(eyed.rig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eyed.eyesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eyed.rigURL.path))
    }

    // MARK: - Eye layers (cut once at install, kept next to the image)

    func testInstallBuildsAndStoresTheEyeLayers() throws {
        let eyed = makeStore(finding: .success(Self.sampleEyes))
        try eyed.install(from: makeImageFile(pixels: 16))

        let rig = try XCTUnwrap(eyed.rig)
        XCTAssertEqual(rig.info, Self.sampleRigInfo)
        XCTAssertEqual(rig.pupils.width, 8)
        XCTAssertEqual(rig.pupils.height, 4)

        // A new store reads them back; it doesn't build again.
        let reopened = makeStore(finding: .failure(.noFace), rig: .failure(.cannotSeparate))
        XCTAssertEqual(reopened.eyes, Self.sampleEyes)
        XCTAssertEqual(reopened.rig?.info, Self.sampleRigInfo)
        XCTAssertEqual(reopened.rig?.clip.width, 8)
    }

    func testEyesThatCannotBeCutOutAreARejection() throws {
        // Found, but no layers: there is nothing to move, so the image has no eyes to offer.
        let eyed = makeStore(finding: .success(Self.sampleEyes), rig: .failure(.noRoomToMove))
        try eyed.install(from: makeImageFile(pixels: 16))

        XCTAssertTrue(eyed.hasImage)
        XCTAssertNil(eyed.eyes)
        XCTAssertNil(eyed.rig)
        XCTAssertEqual(eyed.eyeRejection, .noRoomToMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eyed.rigURL.path))
        XCTAssertEqual(makeStore(finding: .success(Self.sampleEyes)).eyeRejection, .noRoomToMove, "the verdict is kept, not retried every launch")
    }

    func testReplacingWithAnImageWithoutEyesDropsTheOldLayers() throws {
        try makeStore(finding: .success(Self.sampleEyes)).install(from: makeImageFile(pixels: 16))
        let replaced = makeStore(finding: .failure(.noFace))
        XCTAssertNotNil(replaced.rig)
        try replaced.install(from: makeImageFile(pixels: 16))

        XCTAssertNil(replaced.rig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.rigURL.path))
    }

    func testLostLayersAreBuiltAgain() throws {
        let eyed = makeStore(finding: .success(Self.sampleEyes))
        try eyed.install(from: makeImageFile(pixels: 16))
        try FileManager.default.removeItem(at: eyed.rigURL)

        let reopened = makeStore(finding: .success(Self.sampleEyes))
        XCTAssertNil(reopened.eyes, "eyes without layers can't move: not offered")
        XCTAssertNil(reopened.eyeRejection, "and not a verdict either, so it is looked at again")
        reopened.refreshEyesIfNeeded()
        XCTAssertEqual(reopened.eyes, Self.sampleEyes)
        XCTAssertNotNil(reopened.rig)
    }
}
