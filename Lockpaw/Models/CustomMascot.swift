import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The user's own lock-screen image, copied into Application Support so it keeps
/// working after the original is moved or deleted.
///
/// `revision` is what makes SwiftUI re-read the file: the image lives on disk, not
/// in any observed value, so without it the Settings preview would keep showing the
/// previous mascot after a replace.
@MainActor
final class CustomMascot: ObservableObject {
    static let shared = CustomMascot(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
    )

    /// Longest edge the stored image is downsampled to at install. The mascot renders
    /// at a few hundred points, so anything larger is wasted memory on a screen that
    /// stays up for hours — a full-size photo would otherwise sit decoded at ~200 MB.
    static let maxPixelSize = 1024

    private static let fileName = "CustomMascot.png"
    /// Where the eyes are (or why there are none), found once at install. See `MascotEyes`.
    private static let eyesFileName = "CustomMascotEyes.json"
    /// The eyes' cut-out layers, built once at install. See `EyeRig`.
    private static let rigFileName = "CustomMascotRig.png"

    typealias EyeFinding = (CGImage) -> Result<MascotEyes, EyeRejection>
    typealias RigBuilding = (CGImage, MascotEyes) -> Result<EyeRig.Layers, EyeRejection>

    let directory: URL

    @Published private(set) var revision = 0

    /// Cached rather than stat'd on demand: view bodies read it, and the lock screen
    /// re-evaluates its body on every breath frame.
    @Published private(set) var hasImage: Bool

    /// The custom image's eyes, when it has one clear, straight-on pair whose pupils could
    /// be cut out to move. Nil otherwise, with `eyeRejection` saying why (nil there too
    /// means not looked at yet).
    @Published private(set) var eyes: MascotEyes? = nil
    @Published private(set) var eyeRejection: EyeRejection? = nil
    /// The layers that move those eyes. Set exactly when `eyes` is.
    @Published private(set) var rig: MascotRig? = nil

    private var cached: NSImage?
    private let findEyes: EyeFinding
    private let buildRig: RigBuilding
    private let eyesRevision: Int

    init(
        directory: URL,
        findEyes: @escaping EyeFinding = EyeFinder.find,
        buildRig: @escaping RigBuilding = EyeRigImages.build,
        eyesRevision: Int = EyeFinder.revision
    ) {
        self.directory = directory
        self.findEyes = findEyes
        self.buildRig = buildRig
        self.eyesRevision = eyesRevision
        self.hasImage = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.fileName).path
        )
        if hasImage, let record = loadEyesRecord(), record.revision == eyesRevision {
            if let found = record.eyes {
                // Eyes without their layers (file lost, or unreadable) count as not looked
                // at yet, so `refreshEyesIfNeeded` builds them again.
                if let info = record.rig, let data = try? Data(contentsOf: rigURL),
                   let loaded = EyeRigImages.rig(fromAtlas: data, info: info) {
                    eyes = found
                    rig = loaded
                }
            } else {
                eyeRejection = record.rejection
            }
        }
    }

    /// Always a real PNG: `install` re-encodes whatever the user picked.
    var imageURL: URL { directory.appendingPathComponent(Self.fileName) }

    var eyesURL: URL { directory.appendingPathComponent(Self.eyesFileName) }

    var rigURL: URL { directory.appendingPathComponent(Self.rigFileName) }

    /// Whether `mascot` will draw anything. Call sites gate their surrounding glows
    /// and shadows on this so an absent mascot leaves no orphaned lighting.
    func canShow(_ mascot: Mascot) -> Bool {
        mascot.assetName != nil || (mascot == .custom && hasImage)
    }

    func loadImage() -> NSImage? {
        if let cached { return cached }
        guard hasImage, let image = NSImage(contentsOf: imageURL), image.isValid else { return nil }
        cached = image
        return image
    }

    /// Decodes and downsamples before writing, so a junk file can never wipe a working
    /// mascot and an oversized one never reaches disk. The write is atomic for the same reason.
    func install(from source: URL) throws {
        let data = try Data(contentsOf: source)
        guard let png = Self.downsampledPNG(from: data, maxPixelSize: Self.maxPixelSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: imageURL, options: .atomic)

        cached = nil
        hasImage = true
        revision += 1
        detectEyes(in: png)
    }

    /// For an image installed before eyes existed, or found with an older detector.
    /// Cheap when there's nothing to do; blocking (tens of ms) when there is.
    func refreshEyesIfNeeded() {
        guard hasImage, eyes == nil, eyeRejection == nil,
              let png = try? Data(contentsOf: imageURL) else { return }
        detectEyes(in: png)
    }

    /// A failure to find eyes, or to cut their pupils out, never fails the install: the
    /// image still works as a mascot, it just can't look around.
    private func detectEyes(in png: Data) {
        var result: Result<MascotEyes, EyeRejection> = .failure(.noFace)
        var built: (rig: MascotRig, atlas: Data)?
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            result = findEyes(image)
            if case .success(let found) = result {
                switch buildRig(image, found) {
                case .success(let layers):
                    if let atlas = EyeRigImages.atlasPNG(for: layers),
                       let loaded = EyeRigImages.rig(fromAtlas: atlas, info: layers.info) {
                        built = (loaded, atlas)
                    } else {
                        result = .failure(.cannotSeparate)
                    }
                case .failure(let reason):
                    result = .failure(reason)
                }
            }
        }

        let record = MascotEyesRecord(revision: eyesRevision, result: result, rig: built?.rig.info)
        eyes = record.eyes
        eyeRejection = record.rejection
        rig = built?.rig
        if let atlas = built?.atlas {
            try? atlas.write(to: rigURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: rigURL)
        }
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: eyesURL, options: .atomic)
        }
    }

    private func loadEyesRecord() -> MascotEyesRecord? {
        guard let data = try? Data(contentsOf: eyesURL) else { return nil }
        return try? JSONDecoder().decode(MascotEyesRecord.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: eyesURL)
        try? FileManager.default.removeItem(at: rigURL)
        cached = nil
        hasImage = false
        eyes = nil
        eyeRejection = nil
        rig = nil
        revision += 1
    }

    /// Re-encodes `data` as a PNG no larger than `maxPixelSize` on its longest edge.
    /// Smaller images pass through at their own size (never upscaled); EXIF orientation
    /// is baked in so a phone photo lands the right way up. Returns nil for anything
    /// ImageIO cannot decode.
    static func downsampledPNG(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = ImageDownsampling.thumbnail(from: source, maxPixelSize: maxPixelSize)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
