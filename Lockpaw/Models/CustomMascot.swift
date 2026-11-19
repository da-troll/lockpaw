import AppKit

/// The user's own lock-screen image, copied into Application Support so it keeps
/// working after the original is moved or deleted.
///
/// `revision` is what makes SwiftUI re-read the file: the image lives on disk, not
/// in any observed value, so without it the Settings preview would keep showing the
/// previous mascot after a replace.
///
/// One store, two sources. `directory` holds the single image the user chose. With a
/// mascot folder (`MascotFolderController`) the store *shows* one of the folder's prepared
/// images instead (`show(directory:)`): same files, another directory. Everything that
/// draws the custom mascot reads this store and never needs to know which it is.
@MainActor
final class CustomMascot: ObservableObject {
    static let shared = CustomMascot(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
    )

    static let maxPixelSize = MascotPreparer.maxPixelSize

    typealias EyeFinding = MascotPreparer.EyeFinding
    typealias RigBuilding = MascotPreparer.RigBuilding

    /// Where the single custom image lives. `install` and `remove` only ever touch this.
    let directory: URL

    /// The directory being shown: `directory`, or one image of the mascot folder.
    private(set) var shownDirectory: URL

    @Published private(set) var revision = 0

    /// Cached rather than stat'd on demand: view bodies read it, and the lock screen
    /// re-evaluates its body on every breath frame.
    @Published private(set) var hasImage = false

    /// The shown image's eyes, when it has one clear, straight-on pair whose pupils could
    /// be cut out to move. Nil otherwise, with `eyeRejection` saying why (nil there too
    /// means not looked at yet).
    @Published private(set) var eyes: MascotEyes? = nil
    @Published private(set) var eyeRejection: EyeRejection? = nil
    /// The layers that move those eyes. Set exactly when `eyes` is.
    @Published private(set) var rig: MascotRig? = nil

    private var cached: NSImage?
    private let preparer: MascotPreparer
    private var refreshing = false

    init(
        directory: URL,
        findEyes: @escaping EyeFinding = { EyeFinder.find(in: $0) },
        buildRig: @escaping RigBuilding = { EyeRigImages.build(image: $0, eyes: $1) },
        eyesRevision: Int = EyeFinder.revision
    ) {
        self.directory = directory
        self.shownDirectory = directory
        self.preparer = MascotPreparer(findEyes: findEyes, buildRig: buildRig, eyesRevision: eyesRevision)
        reload()
    }

    /// Always a real PNG: `install` re-encodes whatever the user picked.
    var imageURL: URL { directory.appendingPathComponent(MascotPreparer.imageFileName) }

    var eyesURL: URL { directory.appendingPathComponent(MascotPreparer.eyesFileName) }

    var rigURL: URL { directory.appendingPathComponent(MascotPreparer.rigFileName) }

    /// Whether `mascot` will draw anything. Call sites gate their surrounding glows
    /// and shadows on this so an absent mascot leaves no orphaned lighting.
    func canShow(_ mascot: Mascot) -> Bool {
        mascot.assetName != nil || (mascot == .custom && hasImage)
    }

    func loadImage() -> NSImage? {
        if let cached { return cached }
        let url = shownDirectory.appendingPathComponent(MascotPreparer.imageFileName)
        guard hasImage, let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cached = image
        return image
    }

    /// Decodes and downsamples before writing, so a junk file can never wipe a working
    /// mascot and an oversized one never reaches disk. The write is atomic for the same reason.
    func install(from source: URL) throws {
        try preparer.prepare(source: source, into: directory)
        reload()
        revision += 1
    }

    /// For an image installed before eyes existed, or found with an older detector.
    /// Cheap when there's nothing to do; blocking (tens of ms) when there is.
    func refreshEyesIfNeeded() {
        guard hasImage, eyes == nil, eyeRejection == nil else { return }
        if preparer.refreshEyesIfStale(in: shownDirectory) { reload() }
    }

    /// The same, off the main thread: finding eyes and cutting the layers takes long enough
    /// (seconds in a Debug build) to freeze Settings if done as its rows appear.
    func refreshEyesInBackground() {
        guard hasImage, eyes == nil, eyeRejection == nil, !refreshing else { return }
        refreshing = true
        let target = shownDirectory, preparer = preparer
        Task { @MainActor [weak self] in
            let changed = await Task.detached(priority: .userInitiated) { preparer.refreshEyesIfStale(in: target) }.value
            guard let self else { return }
            self.refreshing = false
            if changed, self.shownDirectory == target { self.reload() }
        }
    }

    func remove() {
        for url in [imageURL, eyesURL, rigURL] { try? FileManager.default.removeItem(at: url) }
        reload()
        revision += 1
    }

    /// Shows the prepared image in `other` (one of the mascot folder's), or goes back to
    /// the single custom image with nil. Nothing is copied or written.
    func show(directory other: URL?) {
        let target = other ?? directory
        guard target != shownDirectory else { return }
        shownDirectory = target
        reload()
        revision += 1
    }

    /// Reads the shown directory's state from disk.
    private func reload() {
        cached = nil
        let present = MascotPreparer.hasImage(in: shownDirectory)
        let prepared = present ? preparer.load(from: shownDirectory) : MascotPreparer.Prepared()
        hasImage = present
        eyes = prepared.rig == nil ? nil : prepared.record?.eyes
        eyeRejection = prepared.record?.rejection
        rig = prepared.rig
    }
}
