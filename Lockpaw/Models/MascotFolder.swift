import Foundation

/// A folder of images to use as the custom mascot, one picked at random each time the
/// screen locks. Pure: which files count, when one has to be prepared again, which one is
/// picked, and what Settings says about it. `MascotFolderController` does the disk work.
///
/// Every image is prepared ahead of time (downsampled, eyes found, pupils cut out) and kept
/// in Application Support, so locking never reads the folder: no work as the cover goes
/// up, no permission prompt behind it, and an unplugged drive doesn't blank the mascot.
enum MascotFolder {
    /// The most images used from one folder. Preparing is real work (a laptop's fans can
    /// spin up) and each prepared image is about 1.5 MB on disk, so the set stays small.
    static let maxImages = 20

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// One file in the chosen folder.
    struct File: Equatable, Sendable {
        var name: String
        var size: Int
        var modified: Date
    }

    /// One image of the folder, prepared (or found unreadable) and kept under `id`.
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        /// False for a file ImageIO couldn't decode. Remembered so it isn't tried again
        /// on every scan; never picked.
        var readable: Bool
        var hasEyes: Bool
    }

    /// What the last scan found, kept next to the prepared images.
    struct Index: Codable, Equatable, Sendable {
        var folder: String
        /// Images in the folder, including any beyond `maxImages`.
        var found: Int
        var entries: [Entry]

        var usable: [Entry] { entries.filter(\.readable) }
    }

    static func isImage(_ file: File) -> Bool {
        guard !file.name.hasPrefix(".") else { return false }
        return imageExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    /// The images used: by name, the way Finder lists them, and no more than `maxImages`.
    /// By name rather than at random so the same twenty are used on every scan.
    static func candidates(_ files: [File]) -> [File] {
        let images = files.filter(isImage).sorted {
            let order = $0.name.compare($1.name, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
        return Array(images.prefix(maxImages))
    }

    /// Names the prepared copy of a file. Name, size and modification time all go in, so an
    /// image edited in place is prepared again and its old copy dropped. FNV-1a, because
    /// Swift's own hashing changes from launch to launch.
    static func id(for file: File) -> String {
        let key = "\(file.name)|\(file.size)|\(Int64((file.modified.timeIntervalSince1970 * 1000).rounded()))"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    struct Plan: Equatable {
        /// Files with no prepared copy yet.
        var prepare: [File]
        /// Prepared copies whose file is gone, changed, or no longer among the first twenty.
        var remove: [String]
    }

    static func plan(candidates: [File], cached: Set<String>) -> Plan {
        let wanted = Set(candidates.map(id(for:)))
        return Plan(
            prepare: candidates.filter { !cached.contains(id(for: $0)) },
            remove: cached.subtracting(wanted).sorted()
        )
    }

    /// The image for this lock: any of them, but not the one shown last time when there is
    /// another to show.
    static func pick<G: RandomNumberGenerator>(from ids: [String], last: String?, using generator: inout G) -> String? {
        guard ids.count > 1 else { return ids.first }
        let fresh = ids.filter { $0 != last }
        return fresh.randomElement(using: &generator)
    }

    // MARK: - What Settings says

    enum State: Equatable {
        case notChosen
        case preparing(done: Int, total: Int)
        /// `shown` readable images in use, `withEyes` of them with eyes that move, out of
        /// `found` images in the folder.
        case ready(shown: Int, withEyes: Int, found: Int)
        /// The folder can't be read right now; `shown` images prepared earlier still work.
        case missing(shown: Int)
    }

    static func statusText(_ state: State) -> String {
        switch state {
        case .notChosen:
            return "Up to \(maxImages) images, one picked each time you lock. Preparing them is a one-time job that can make a laptop's fans spin up for a moment."
        case .preparing(let done, let total):
            let count = total > 0 ? "Preparing image \(min(done + 1, total)) of \(total)." : "Looking through the folder\u{2026}"
            return "\(count) A one-time job. Your Mac may be busy for a moment."
        case .ready(let shown, let withEyes, let found):
            guard shown > 0 else { return "No images in this folder." }
            let images = found > maxImages
                ? "Using the first \(shown) of \(found) images"
                : "\(shown) image\(shown == 1 ? "" : "s")"
            return "\(images), \(withEyes == 0 ? "none" : "\(withEyes)") with moving eyes."
        case .missing(let shown):
            return shown > 0
                ? "Folder not found. Using the \(shown) image\(shown == 1 ? "" : "s") prepared earlier."
                : "Folder not found."
        }
    }
}
