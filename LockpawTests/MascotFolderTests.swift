import XCTest
import AppKit
@testable import Lockpaw

final class MascotFolderTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, size: Int = 1000, modified: Date? = nil) -> MascotFolder.File {
        MascotFolder.File(name: name, size: size, modified: modified ?? day)
    }

    // MARK: - Which files

    func testOnlyImagesCount() {
        let files = [file("a.png"), file("b.JPG"), file("c.heic"), file("notes.txt"), file("clip.mov"), file(".hidden.png"), file("noextension")]
        XCTAssertEqual(MascotFolder.candidates(files).map(\.name), ["a.png", "b.JPG", "c.heic"])
    }

    func testImagesAreUsedInFinderOrder() {
        let files = [file("mascot 10.png"), file("Mascot 2.png"), file("apple.png"), file("mascot 1.png")]
        XCTAssertEqual(MascotFolder.candidates(files).map(\.name), ["apple.png", "mascot 1.png", "Mascot 2.png", "mascot 10.png"])
    }

    func testNoMoreThanTwentyAndAlwaysTheSameTwenty() {
        XCTAssertEqual(MascotFolder.maxImages, 20)
        let files = (1...34).map { file("img \($0).png") }
        let used = MascotFolder.candidates(files)
        XCTAssertEqual(used.count, 20)
        XCTAssertEqual(used.first?.name, "img 1.png")
        XCTAssertEqual(used.last?.name, "img 20.png")
        XCTAssertEqual(MascotFolder.candidates(files.shuffled()), used, "the order files are listed in doesn't matter")
    }

    // MARK: - When to prepare again

    func testIDIsStableAndChangesWhenTheFileDoes() {
        let original = file("owl.png")
        XCTAssertEqual(MascotFolder.id(for: original), MascotFolder.id(for: file("owl.png")))
        XCTAssertNotEqual(MascotFolder.id(for: original), MascotFolder.id(for: file("owl2.png")))
        XCTAssertNotEqual(MascotFolder.id(for: original), MascotFolder.id(for: file("owl.png", size: 1001)))
        XCTAssertNotEqual(MascotFolder.id(for: original), MascotFolder.id(for: file("owl.png", modified: day + 1)))
        // Fixed, not Swift's per-launch hash: a directory named by it must be found next launch.
        XCTAssertEqual(MascotFolder.id(for: file("a.png", size: 1, modified: Date(timeIntervalSince1970: 0))),
                       MascotFolder.id(for: file("a.png", size: 1, modified: Date(timeIntervalSince1970: 0))))
        XCTAssertTrue(MascotFolder.id(for: original).allSatisfy { $0.isHexDigit })
    }

    func testPlanPreparesWhatIsNewAndDropsWhatIsGone() {
        let kept = file("kept.png"), added = file("added.png")
        let goneID = MascotFolder.id(for: file("gone.png"))
        let plan = MascotFolder.plan(candidates: [added, kept], cached: [MascotFolder.id(for: kept), goneID])
        XCTAssertEqual(plan.prepare, [added])
        XCTAssertEqual(plan.remove, [goneID])
    }

    func testAnEditedImageIsPreparedAgainAndItsOldCopyDropped() {
        let before = file("owl.png"), after = file("owl.png", modified: day + 60)
        let plan = MascotFolder.plan(candidates: [after], cached: [MascotFolder.id(for: before)])
        XCTAssertEqual(plan.prepare, [after])
        XCTAssertEqual(plan.remove, [MascotFolder.id(for: before)])
    }

    func testNothingToDoWhenNothingChanged() {
        let files = [file("a.png"), file("b.png")]
        let plan = MascotFolder.plan(candidates: files, cached: Set(files.map(MascotFolder.id(for:))))
        XCTAssertEqual(plan, MascotFolder.Plan(prepare: [], remove: []))
    }

    // MARK: - Which image this lock

    func testNeverTheSameImageTwiceInARow() {
        var generator = SystemRandomNumberGenerator()
        let ids = ["a", "b", "c"]
        var last: String?
        var seen = Set<String>()
        for _ in 0..<200 {
            let pick = MascotFolder.pick(from: ids, last: last, using: &generator)
            XCTAssertNotNil(pick)
            XCTAssertNotEqual(pick, last)
            seen.insert(pick ?? "")
            last = pick
        }
        XCTAssertEqual(seen, Set(ids), "every image gets its turn")
    }

    func testOneImageIsAlwaysThatImage() {
        var generator = SystemRandomNumberGenerator()
        XCTAssertEqual(MascotFolder.pick(from: ["only"], last: "only", using: &generator), "only")
        XCTAssertNil(MascotFolder.pick(from: [], last: "gone", using: &generator))
    }

    func testAPickThatNoLongerExistsDoesNotNarrowTheChoice() {
        var generator = SystemRandomNumberGenerator()
        var seen = Set<String>()
        for _ in 0..<100 { seen.insert(MascotFolder.pick(from: ["a", "b"], last: "removed", using: &generator) ?? "") }
        XCTAssertEqual(seen, ["a", "b"])
    }

    // MARK: - What Settings says

    func testTheHeavyWorkIsAnnouncedBeforeAndDuring() {
        let before = MascotFolder.statusText(.notChosen)
        XCTAssertTrue(before.contains("Up to 20 images"))
        XCTAssertTrue(before.contains("one-time job"))
        XCTAssertTrue(before.contains("fans"))

        let during = MascotFolder.statusText(.preparing(done: 2, total: 14))
        XCTAssertTrue(during.hasPrefix("Preparing image 3 of 14."))
        XCTAssertTrue(during.contains("one-time job"))
        XCTAssertTrue(MascotFolder.statusText(.preparing(done: 14, total: 14)).hasPrefix("Preparing image 14 of 14."))
        XCTAssertTrue(MascotFolder.statusText(.preparing(done: 0, total: 0)).hasPrefix("Looking through the folder"))
    }

    func testReadyTextCountsImagesAndEyes() {
        XCTAssertEqual(MascotFolder.statusText(.ready(shown: 14, withEyes: 11, found: 14)), "14 images, 11 with moving eyes.")
        XCTAssertEqual(MascotFolder.statusText(.ready(shown: 1, withEyes: 1, found: 1)), "1 image, 1 with moving eyes.")
        XCTAssertEqual(MascotFolder.statusText(.ready(shown: 3, withEyes: 0, found: 3)), "3 images, none with moving eyes.")
        XCTAssertEqual(MascotFolder.statusText(.ready(shown: 20, withEyes: 9, found: 34)), "Using the first 20 of 34 images, 9 with moving eyes.")
        XCTAssertEqual(MascotFolder.statusText(.ready(shown: 0, withEyes: 0, found: 0)), "No images in this folder.")
    }

    func testAMissingFolderKeepsWhatWasPrepared() {
        XCTAssertEqual(MascotFolder.statusText(.missing(shown: 5)), "Folder not found. Using the 5 images prepared earlier.")
        XCTAssertEqual(MascotFolder.statusText(.missing(shown: 0)), "Folder not found.")
    }

    func testOnlyImagesWithMovingEyesWhenAsked() {
        let still = MascotFolder.Entry(id: "a", name: "a.png", readable: true, hasEyes: false)
        let moving = MascotFolder.Entry(id: "b", name: "b.png", readable: true, hasEyes: true)
        XCTAssertEqual(MascotFolder.choosable([still, moving], onlyWithEyes: true), [moving])
        XCTAssertEqual(MascotFolder.choosable([still, moving], onlyWithEyes: false), [still, moving])
    }

    func testAFolderWithoutMovingEyesStillShowsItsImages() {
        let still = MascotFolder.Entry(id: "a", name: "a.png", readable: true, hasEyes: false)
        XCTAssertEqual(MascotFolder.choosable([still], onlyWithEyes: true), [still])
    }

    func testNoEmDashesInTheCopy() {
        let states: [MascotFolder.State] = [.notChosen, .preparing(done: 0, total: 3), .ready(shown: 2, withEyes: 1, found: 2), .missing(shown: 1)]
        for state in states { XCTAssertFalse(MascotFolder.statusText(state).contains("\u{2014}")) }
    }
}

/// The folder's disk work and the store that shows its images, against temporary directories.
@MainActor
final class MascotFolderDiskTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var cache: URL!

    private static let sampleEyes = MascotEyes(
        left: .init(center: CGPoint(x: 0.4, y: 0.4), size: CGSize(width: 0.08, height: 0.03)),
        right: .init(center: CGPoint(x: 0.6, y: 0.4), size: CGSize(width: 0.08, height: 0.03)),
        revision: 3
    )

    private static var sampleLayers: EyeRig.Layers {
        let layer = EyeRig.Bitmap(width: 8, height: 4, rgba: [UInt8](repeating: 200, count: 8 * 4 * 4))
        let info = EyeRig.Info(version: 1, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
                               travel: .init(left: 0.02, right: 0.02, up: 0.01, down: 0.01))
        return EyeRig.Layers(plate: layer, pupils: layer, clip: layer, info: info)
    }

    /// Finds eyes in every image at least 32 px wide, none in smaller ones.
    private func preparer(revision: Int = 3) -> MascotPreparer {
        let eyes = Self.sampleEyes, layers = Self.sampleLayers
        return MascotPreparer(
            findEyes: { $0.width >= 32 ? .success(eyes) : .failure(.noFace) },
            buildRig: { _, _ in .success(layers) },
            eyesRevision: revision
        )
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MascotFolderTests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Pictures", isDirectory: true)
        cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func addImage(_ name: String, pixels: Int = 48) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let url = folder.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func sync(revision: Int = 3, progress: (Int, Int) -> Void = { _, _ in }) -> MascotFolder.Index? {
        MascotFolderDisk.sync(folder: folder, cache: cache, preparer: preparer(revision: revision), progress: progress)
    }

    // MARK: - Sync

    func testPreparesEveryImageOnceAndRemembersIt() throws {
        try addImage("a.png")
        try addImage("b.png", pixels: 16)
        try "not an image".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        var steps: [[Int]] = []
        let index = try XCTUnwrap(sync { steps.append([$0, $1]) })
        XCTAssertEqual(index.entries.map(\.name), ["a.png", "b.png"])
        XCTAssertEqual(index.entries.map(\.hasEyes), [true, false], "an image without eyes is still used")
        XCTAssertEqual(index.found, 2)
        XCTAssertEqual(steps, [[0, 2], [1, 2]])
        XCTAssertEqual(MascotFolderDisk.readIndex(in: cache), index)
        for entry in index.entries {
            XCTAssertTrue(MascotPreparer.hasImage(in: MascotFolderDisk.directory(for: entry.id, in: cache)))
        }

        // The one-time job really is one time: a second scan prepares nothing.
        steps = []
        XCTAssertEqual(sync { steps.append([$0, $1]) }, index)
        XCTAssertEqual(steps, [])
    }

    func testEachImageIsOfferedAsSoonAsItIsReady() throws {
        try addImage("a.png")
        try addImage("b.png")
        var events: [String] = []
        _ = MascotFolderDisk.sync(
            folder: folder, cache: cache, preparer: preparer(),
            progress: { done, _ in events.append("work \(done)") },
            ready: { events.append("ready \($0.name)") }
        )
        XCTAssertEqual(events, ["work 0", "ready a.png", "work 1", "ready b.png"], "the first is usable before the second is started")

        // Next time, what is already prepared is offered at once, before any new work.
        try addImage("c.png")
        events = []
        _ = MascotFolderDisk.sync(
            folder: folder, cache: cache, preparer: preparer(),
            progress: { done, _ in events.append("work \(done)") },
            ready: { events.append("ready \($0.name)") }
        )
        XCTAssertEqual(events, ["ready a.png", "ready b.png", "work 0", "ready c.png"])
    }

    func testAddedAndRemovedImagesAreNoticed() throws {
        try addImage("a.png")
        let removed = try addImage("b.png")
        let first = try XCTUnwrap(sync())
        let removedID = try XCTUnwrap(first.entries.last?.id)

        try FileManager.default.removeItem(at: removed)
        try addImage("c.png")
        var prepared = 0
        let second = try XCTUnwrap(sync { _, _ in prepared += 1 })
        XCTAssertEqual(second.entries.map(\.name), ["a.png", "c.png"])
        XCTAssertEqual(prepared, 1, "only the new one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MascotFolderDisk.directory(for: removedID, in: cache).path))
    }

    func testAFileThatIsNotReallyAnImageIsSkippedAndNotRetried() throws {
        try addImage("good.png")
        try Data([1, 2, 3, 4]).write(to: folder.appendingPathComponent("broken.png"))

        let index = try XCTUnwrap(sync())
        XCTAssertEqual(index.entries.map(\.readable), [false, true])
        XCTAssertEqual(index.usable.map(\.name), ["good.png"])
        XCTAssertEqual(index.found, 2)

        var prepared = 0
        _ = sync { _, _ in prepared += 1 }
        XCTAssertEqual(prepared, 0)
    }

    func testANewerDetectorLooksAgainWithoutTheOriginals() throws {
        try addImage("a.png")
        _ = try XCTUnwrap(sync(revision: 2))
        var steps: [[Int]] = []
        let index = try XCTUnwrap(sync(revision: 3) { steps.append([$0, $1]) })
        XCTAssertEqual(steps, [[0, 1]])
        XCTAssertEqual(index.entries.map(\.hasEyes), [true])
    }

    func testAMissingFolderChangesNothing() throws {
        try addImage("a.png")
        let index = try XCTUnwrap(sync())
        try FileManager.default.removeItem(at: folder)

        XCTAssertNil(sync())
        XCTAssertEqual(MascotFolderDisk.readIndex(in: cache), index, "what was prepared still works")
        XCTAssertTrue(MascotPreparer.hasImage(in: MascotFolderDisk.directory(for: index.entries[0].id, in: cache)))
    }

    func testCancellingKeepsWhatIsDoneAndWritesNoIndex() throws {
        try addImage("a.png")
        try addImage("b.png")
        var calls = 0
        let result = MascotFolderDisk.sync(folder: folder, cache: cache, preparer: preparer(), isCancelled: {
            calls += 1
            return calls > 1 // stop after the first image
        })
        XCTAssertNil(result)
        XCTAssertNil(MascotFolderDisk.readIndex(in: cache))
        XCTAssertEqual(MascotFolderDisk.cachedIDs(in: cache).count, 1)

        var prepared = 0
        XCTAssertEqual(sync { _, _ in prepared += 1 }?.entries.count, 2)
        XCTAssertEqual(prepared, 1, "the next scan only does the rest")
    }

    func testOnlyTheFirstTwentyArePrepared() throws {
        for i in 1...23 { try addImage("img \(i).png", pixels: 8) }
        let index = try XCTUnwrap(sync())
        XCTAssertEqual(index.entries.count, 20)
        XCTAssertEqual(index.found, 23)
        XCTAssertEqual(MascotFolderDisk.cachedIDs(in: cache).count, 20)
    }

    // MARK: - Showing one

    func testTheStoreShowsAFolderImageAndGoesBack() throws {
        try addImage("a.png")
        let index = try XCTUnwrap(sync())
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let eyes = Self.sampleEyes, layers = Self.sampleLayers
        let store = CustomMascot(directory: home, findEyes: { _ in .success(eyes) }, buildRig: { _, _ in .success(layers) }, eyesRevision: 3)
        XCTAssertFalse(store.hasImage)

        let before = store.revision
        store.show(directory: MascotFolderDisk.directory(for: index.entries[0].id, in: cache))
        XCTAssertTrue(store.hasImage)
        XCTAssertNotNil(store.loadImage())
        XCTAssertEqual(store.eyes, Self.sampleEyes)
        XCTAssertNotNil(store.rig)
        XCTAssertGreaterThan(store.revision, before, "views have to redraw")
        XCTAssertFalse(MascotPreparer.hasImage(in: home), "nothing is copied into the single image's place")

        store.show(directory: nil)
        XCTAssertFalse(store.hasImage)
        XCTAssertNil(store.eyes)
        XCTAssertNil(store.rig)
    }

    func testShowingTheSameImageAgainDoesNotRedraw() throws {
        try addImage("a.png")
        let index = try XCTUnwrap(sync())
        let store = CustomMascot(directory: root.appendingPathComponent("Home"), eyesRevision: 3)
        let entry = MascotFolderDisk.directory(for: index.entries[0].id, in: cache)
        store.show(directory: entry)
        let revision = store.revision
        store.show(directory: entry)
        XCTAssertEqual(store.revision, revision)
    }

    // MARK: - Controller

    private func makeController(source: String?, unlocked: Bool = true) -> (MascotFolderController, CustomMascot, UserDefaults) {
        let suite = "MascotFolderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let source { defaults.set(source, forKey: MascotFolderController.sourceKey) }
        defaults.set(folder.path, forKey: MascotFolderController.pathKey)
        let store = CustomMascot(directory: root.appendingPathComponent("Home"), eyesRevision: 3)
        let controller = MascotFolderController(cache: cache, store: store, defaults: defaults, preparer: preparer(), isUnlocked: { unlocked })
        return (controller, store, defaults)
    }

    func testEachLockShowsOneOfThePreparedImages() throws {
        try addImage("a.png")
        try addImage("b.png")
        try addImage("c.png")
        let index = try XCTUnwrap(sync())
        let (controller, store, _) = makeController(source: MascotFolderController.folderSource)
        XCTAssertEqual(controller.usable.count, 3, "read from the index, no scan needed")

        let directories = Set(index.entries.map { MascotFolderDisk.directory(for: $0.id, in: cache) })
        var previous: URL?
        var seen = Set<URL>()
        for _ in 0..<60 {
            controller.lockStarted()
            XCTAssertTrue(store.hasImage)
            XCTAssertTrue(directories.contains(store.shownDirectory))
            XCTAssertNotEqual(store.shownDirectory, previous)
            previous = store.shownDirectory
            seen.insert(store.shownDirectory)
        }
        XCTAssertEqual(seen, directories)
    }

    func testOneImageSourceIsLeftAlone() throws {
        try addImage("a.png")
        _ = try XCTUnwrap(sync())
        let (controller, store, _) = makeController(source: nil)
        controller.lockStarted()
        XCTAssertEqual(store.shownDirectory, store.directory)
        XCTAssertEqual(controller.state, .ready(shown: 1, withEyes: 1, found: 1))
    }

    func testAnEmptyFolderFallsBackToTheSingleImage() {
        let (controller, store, _) = makeController(source: MascotFolderController.folderSource)
        controller.lockStarted()
        XCTAssertEqual(store.shownDirectory, store.directory)
    }

    func testTheFolderIsNeverReadWhileLocked() throws {
        try addImage("a.png")
        let (controller, _, _) = makeController(source: MascotFolderController.folderSource, unlocked: false)
        controller.rescan()
        XCTAssertNil(controller.progress)
        XCTAssertTrue(MascotFolderDisk.cachedIDs(in: cache).isEmpty)
    }

    func testChoosingAFolderPreparesItInTheBackground() async throws {
        try addImage("a.png")
        try addImage("b.png", pixels: 16)
        let (controller, store, defaults) = makeController(source: MascotFolderController.folderSource)
        defaults.removeObject(forKey: MascotFolderController.pathKey)

        controller.choose(folder)
        XCTAssertNotNil(controller.progress, "Settings says it's working straight away")
        for _ in 0..<200 where controller.progress != nil { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertNil(controller.progress)
        XCTAssertEqual(controller.state, .ready(shown: 2, withEyes: 1, found: 2))
        XCTAssertEqual(defaults.string(forKey: MascotFolderController.pathKey), folder.path)
        XCTAssertTrue(store.hasImage, "the preview has something to show without locking first")
    }
}
