import CoreGraphics
import Foundation
import ImageIO

/// Turns a picked image file into what the lock screen draws: a downsampled PNG, the eyes
/// found in it, and the layers that move them, all written into one directory.
///
/// `CustomMascot` uses it for the single custom image; the mascot folder uses it once per
/// image, into a directory each. No shared state and nothing tied to the main thread, so
/// a folder can be prepared in the background.
struct MascotPreparer: Sendable {
    typealias EyeFinding = @Sendable (CGImage) -> Result<MascotEyes, EyeRejection>
    typealias RigBuilding = @Sendable (CGImage, MascotEyes) -> Result<EyeRig.Layers, EyeRejection>

    static let imageFileName = "CustomMascot.png"
    /// Where the eyes are (or why there are none), found once at install. See `MascotEyes`.
    static let eyesFileName = "CustomMascotEyes.json"
    /// The eyes' cut-out layers, built once at install. See `EyeRig`.
    static let rigFileName = "CustomMascotRig.png"

    /// Longest edge the stored image is downsampled to. The mascot renders at a few hundred
    /// points, so anything larger is wasted memory on a screen that stays up for hours: a
    /// full-size photo would otherwise sit decoded at ~200 MB.
    static let maxPixelSize = 1024

    var findEyes: EyeFinding = { EyeFinder.find(in: $0) }
    var buildRig: RigBuilding = { EyeRigImages.build(image: $0, eyes: $1) }
    var eyesRevision: Int = EyeFinder.revision

    /// What one prepared directory holds, read back from disk.
    struct Prepared {
        var record: MascotEyesRecord?
        var rig: MascotRig?
    }

    /// Decodes and downsamples before writing, so a junk file can never wipe a working
    /// mascot and an oversized one never reaches disk. The writes are atomic for the same
    /// reason. Throws for anything that isn't an image; a failure to find eyes is not an
    /// error (see `writeEyes`).
    func prepare(source: URL, into directory: URL) throws {
        let data = try Data(contentsOf: source)
        guard let png = ImageDownsampling.downsampledPNG(from: data, maxPixelSize: Self.maxPixelSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(Self.imageFileName), options: .atomic)
        writeEyes(for: png, in: directory)
    }

    /// Finds the eyes in `png` and cuts their layers, and writes both next to the image.
    /// A failure at either step is recorded as the reason, never thrown: the image still
    /// works as a mascot, it just can't look around.
    func writeEyes(for png: Data, in directory: URL) {
        var result: Result<MascotEyes, EyeRejection> = .failure(.noFace)
        var built: (info: EyeRig.Info, atlas: Data)?
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            result = findEyes(image)
            if case .success(let found) = result {
                switch buildRig(image, found) {
                case .success(let layers):
                    if let atlas = EyeRigImages.atlasPNG(for: layers),
                       EyeRigImages.rig(fromAtlas: atlas, info: layers.info) != nil {
                        built = (layers.info, atlas)
                    } else {
                        result = .failure(.cannotSeparate)
                    }
                case .failure(let reason):
                    result = .failure(reason)
                }
            }
        }

        let rigURL = directory.appendingPathComponent(Self.rigFileName)
        if let atlas = built?.atlas {
            try? atlas.write(to: rigURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: rigURL)
        }
        let record = MascotEyesRecord(revision: eyesRevision, result: result, rig: built?.info)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: directory.appendingPathComponent(Self.eyesFileName), options: .atomic)
        }
    }

    /// For an image prepared before eyes existed, or with an older detector: looks again,
    /// from the stored PNG. Returns false when there was nothing to redo.
    @discardableResult
    func refreshEyesIfStale(in directory: URL) -> Bool {
        guard !eyesAreCurrent(in: directory) else { return false }
        guard let png = try? Data(contentsOf: directory.appendingPathComponent(Self.imageFileName)) else { return false }
        writeEyes(for: png, in: directory)
        return true
    }

    /// Whether `directory` has a verdict from this detector, with its layers if it found eyes.
    func eyesAreCurrent(in directory: URL) -> Bool {
        guard let record = Self.record(in: directory), record.revision == eyesRevision else { return false }
        return record.eyes == nil
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.rigFileName).path)
    }

    /// The eyes verdict and layers in `directory`, as far as they are current and complete.
    /// Eyes without their layers (file lost, or unreadable) come back as no record at all,
    /// which reads as "not looked at yet".
    func load(from directory: URL) -> Prepared {
        guard let record = Self.record(in: directory), record.revision == eyesRevision else { return Prepared() }
        guard record.eyes != nil else { return Prepared(record: record, rig: nil) }
        guard let info = record.rig,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.rigFileName)),
              let rig = EyeRigImages.rig(fromAtlas: data, info: info)
        else { return Prepared() }
        return Prepared(record: record, rig: rig)
    }

    static func record(in directory: URL) -> MascotEyesRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(eyesFileName)) else { return nil }
        return try? JSONDecoder().decode(MascotEyesRecord.self, from: data)
    }

    static func hasImage(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(imageFileName).path)
    }
}
