import AppKit
import os.log

/// The mascot folder's disk work: reading the chosen folder, preparing each image into its
/// own directory under the cache, and keeping the index. No shared state, so it runs in
/// the background and is tested against temporary directories.
enum MascotFolderDisk {
    private static let indexFileName = "index.json"
    private static let pendingSuffix = ".tmp"

    /// The plain files in `folder`, or nil when it can't be read (gone, unmounted, denied).
    static func list(_ folder: URL) -> [MascotFolder.File]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return MascotFolder.File(
                name: url.lastPathComponent,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    static func directory(for id: String, in cache: URL) -> URL {
        cache.appendingPathComponent(id, isDirectory: true)
    }

    static func cachedIDs(in cache: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return Set(urls.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDirectory && !url.lastPathComponent.hasSuffix(pendingSuffix) ? url.lastPathComponent : nil
        })
    }

    static func readIndex(in cache: URL) -> MascotFolder.Index? {
        guard let data = try? Data(contentsOf: cache.appendingPathComponent(indexFileName)) else { return nil }
        return try? JSONDecoder().decode(MascotFolder.Index.self, from: data)
    }

    /// Brings the cache in line with `folder`: prepares what's new, drops what's gone,
    /// looks again at anything an older detector judged. Blocking, and the heavy part of
    /// the feature: call it off the main thread. `progress` is told before each image it
    /// works on, and `ready` each time an image can be shown (those already prepared
    /// first, then each new one as it is done), so the first image is on screen long
    /// before the last is finished. Returns nil, changing no index, when the folder can't
    /// be read or `isCancelled` says stop; whatever was prepared so far is kept for the
    /// next run.
    static func sync(
        folder: URL,
        cache: URL,
        preparer: MascotPreparer,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        ready: (MascotFolder.Entry) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> MascotFolder.Index? {
        guard let files = list(folder) else { return nil }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)

        let candidates = MascotFolder.candidates(files)
        let plan = MascotFolder.plan(candidates: candidates, cached: cachedIDs(in: cache))
        for id in plan.remove { try? fileManager.removeItem(at: directory(for: id, in: cache)) }

        let fresh = Set(plan.prepare.map(MascotFolder.id(for:)))
        let stale = candidates.filter { file in
            let id = MascotFolder.id(for: file)
            let kept = directory(for: id, in: cache)
            return !fresh.contains(id) && MascotPreparer.hasImage(in: kept) && !preparer.eyesAreCurrent(in: kept)
        }

        func entry(for file: MascotFolder.File) -> MascotFolder.Entry {
            let id = MascotFolder.id(for: file)
            let kept = directory(for: id, in: cache)
            let readable = MascotPreparer.hasImage(in: kept)
            return MascotFolder.Entry(
                id: id, name: file.name, readable: readable,
                hasEyes: readable && preparer.load(from: kept).rig != nil
            )
        }

        let staleIDs = Set(stale.map(MascotFolder.id(for:)))
        for file in candidates where !fresh.contains(MascotFolder.id(for: file)) && !staleIDs.contains(MascotFolder.id(for: file)) {
            ready(entry(for: file))
        }

        let total = plan.prepare.count + stale.count
        var done = 0
        for file in plan.prepare {
            if isCancelled() { return nil }
            progress(done, total)
            prepare(file, from: folder, cache: cache, preparer: preparer)
            ready(entry(for: file))
            done += 1
        }
        for file in stale {
            if isCancelled() { return nil }
            progress(done, total)
            preparer.refreshEyesIfStale(in: directory(for: MascotFolder.id(for: file), in: cache))
            ready(entry(for: file))
            done += 1
        }
        if isCancelled() { return nil }

        let index = MascotFolder.Index(
            folder: folder.path,
            found: files.filter(MascotFolder.isImage).count,
            entries: candidates.map(entry(for:))
        )
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: cache.appendingPathComponent(indexFileName), options: .atomic)
        }
        return index
    }

    /// Prepares into a side directory and moves it into place, so a crash or a quit halfway
    /// through never leaves a half-made image to be picked. A file that isn't an image
    /// after all leaves an empty directory: remembered, so it isn't tried on every scan.
    private static func prepare(_ file: MascotFolder.File, from folder: URL, cache: URL, preparer: MascotPreparer) {
        let fileManager = FileManager.default
        let final = directory(for: MascotFolder.id(for: file), in: cache)
        let pending = final.appendingPathExtension(String(pendingSuffix.dropFirst()))
        try? fileManager.removeItem(at: pending)
        do {
            try preparer.prepare(source: folder.appendingPathComponent(file.name), into: pending)
        } catch {
            try? fileManager.removeItem(at: pending)
            try? fileManager.createDirectory(at: pending, withIntermediateDirectories: true)
        }
        try? fileManager.removeItem(at: final)
        try? fileManager.moveItem(at: pending, to: final)
    }
}

/// Owns the mascot folder: which folder, the prepared images, and which one the lock
/// screen shows. On each lock it picks one and points `CustomMascot` at it; everything that
/// draws the custom mascot goes on reading that store.
///
/// The folder itself is only read while unlocked (when it is chosen, at launch, after
/// each unlock, on Rescan). A prompt for a folder in Documents or Downloads must come up
/// over the desktop, never behind the cover.
@MainActor
final class MascotFolderController: ObservableObject {
    static let shared = MascotFolderController(
        cache: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("MascotFolder", isDirectory: true),
        store: .shared
    )

    /// "image" (the single custom image, the default) or "folder".
    static let sourceKey = "customMascotSource"
    static let imageSource = "image"
    static let folderSource = "folder"
    static let pathKey = "customMascotFolder"

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    @Published private(set) var index: MascotFolder.Index?
    /// Set while images are being prepared.
    @Published private(set) var progress: Progress?
    /// The chosen folder couldn't be read at the last scan.
    @Published private(set) var folderMissing = false
    @Published private(set) var folderURL: URL?

    private let cache: URL
    private let store: CustomMascot
    private let defaults: UserDefaults
    private let preparer: MascotPreparer
    private let isUnlocked: @MainActor () -> Bool
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "MascotFolder")

    private var shownID: String?
    private var lastPicked: String?
    private var generation = 0
    private var worker: Task<MascotFolder.Index?, Never>?

    init(
        cache: URL,
        store: CustomMascot,
        defaults: UserDefaults = .standard,
        preparer: MascotPreparer = MascotPreparer(),
        isUnlocked: @escaping @MainActor () -> Bool = { LockStatus.shared.state == .unlocked }
    ) {
        self.cache = cache
        self.store = store
        self.defaults = defaults
        self.preparer = preparer
        self.isUnlocked = isUnlocked
        self.folderURL = defaults.string(forKey: Self.pathKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.index = MascotFolderDisk.readIndex(in: cache)
    }

    var isFolderSource: Bool { defaults.string(forKey: Self.sourceKey) == Self.folderSource }

    /// Images that can be shown.
    var usable: [MascotFolder.Entry] { index?.usable ?? [] }

    var state: MascotFolder.State {
        guard folderURL != nil else { return .notChosen }
        if let progress { return .preparing(done: progress.done, total: progress.total) }
        if folderMissing { return .missing(shown: usable.count) }
        guard let index else { return .preparing(done: 0, total: 0) }
        return .ready(shown: index.usable.count, withEyes: index.usable.filter(\.hasEyes).count, found: index.found)
    }

    /// At launch: show an image straight away from what was prepared before, then check
    /// the folder for changes.
    func start() {
        showSomething()
        rescan()
    }

    func choose(_ folder: URL) {
        defaults.set(folder.path, forKey: Self.pathKey)
        folderURL = folder
        index = nil
        folderMissing = false
        rescan()
    }

    /// The One image / Folder choice changed in Settings.
    func sourceChanged() {
        showSomething()
        rescan()
    }

    /// Picks the image for this lock. Only reads what is already prepared.
    func lockStarted() {
        guard isFolderSource else { return }
        var generator = SystemRandomNumberGenerator()
        guard let id = MascotFolder.pick(from: usable.map(\.id), last: lastPicked, using: &generator) else {
            show(nil)
            return
        }
        lastPicked = id
        show(id)
    }

    /// Back at the Mac: a good moment to notice images added or removed meanwhile.
    func lockEnded() {
        rescan()
    }

    /// Reads the folder and prepares what changed, in the background. Does nothing while
    /// locked, or when the folder isn't the source.
    func rescan() {
        guard isFolderSource, let folderURL, isUnlocked() else { return }
        worker?.cancel()
        generation += 1
        let run = generation
        progress = Progress(done: 0, total: 0)

        let cache = cache, preparer = preparer
        let work = Task.detached(priority: .utility) { [weak self] () -> MascotFolder.Index? in
            MascotFolderDisk.sync(
                folder: folderURL, cache: cache, preparer: preparer,
                progress: { done, total in
                    Task { @MainActor [weak self] in self?.report(done: done, total: total, run: run) }
                },
                ready: { entry in
                    Task { @MainActor [weak self] in self?.available(entry, folder: folderURL, run: run) }
                },
                isCancelled: { Task.isCancelled }
            )
        }
        worker = work
        Task { @MainActor [weak self] in
            let result = await work.value
            self?.finished(result, folder: folderURL, run: run)
        }
    }

    private func report(done: Int, total: Int, run: Int) {
        guard run == generation, progress != nil else { return }
        progress = Progress(done: done, total: total)
    }

    /// An image can be shown, while the rest are still being prepared: the preview and the
    /// lock screen get it now rather than when the whole folder is done.
    private func available(_ entry: MascotFolder.Entry, folder: URL, run: Int) {
        guard run == generation, progress != nil else { return }
        var current = index?.folder == folder.path ? index : nil
        var entries = current?.entries.filter { $0.id != entry.id } ?? []
        entries.append(entry)
        current = MascotFolder.Index(folder: folder.path, found: max(current?.found ?? 0, entries.count), entries: entries)
        index = current
        showSomething()
    }

    private func finished(_ result: MascotFolder.Index?, folder: URL, run: Int) {
        guard run == generation else { return } // a newer scan took over
        progress = nil
        if let result {
            index = result
            folderMissing = false
            logger.notice("Mascot folder: \(result.usable.count, privacy: .public) images ready, \(result.found, privacy: .public) found")
        } else {
            folderMissing = !FileManager.default.fileExists(atPath: folder.path)
                || MascotFolderDisk.list(folder) == nil
            // Images prepared for another folder are not this folder's images.
            if index?.folder != folder.path { index = nil }
        }
        showSomething()
    }

    /// Keeps the store pointed at something sensible outside of a lock: the image already
    /// shown if it still exists, else the first; the single custom image when the folder
    /// isn't the source or has nothing to show.
    private func showSomething() {
        guard isFolderSource else { return show(nil) }
        let ids = usable.map(\.id)
        if let shownID, ids.contains(shownID) { return }
        show(ids.first)
    }

    private func show(_ id: String?) {
        shownID = id
        store.show(directory: id.map { MascotFolderDisk.directory(for: $0, in: cache) })
    }
}
