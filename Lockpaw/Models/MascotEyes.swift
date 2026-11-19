import CoreGraphics
import Foundation

/// Where the eyes sit in the custom mascot, so the lock screen can make them follow
/// whoever walks past. Pure: `EyeFinder` turns a Vision pass into `FaceCandidate`s and
/// everything that decides whether an image *has* usable eyes lives here, tested.
///
/// Only custom images get eyes. A face we can't place confidently is rejected outright
/// rather than guessed at: a pupil drawn a few pixels off reads as a broken image, not a
/// cute one, so "no gaze for this image" is the honest answer.
///
/// Coordinates are normalized to the image (0...1 on each axis, top-left origin) so they
/// survive any render size. `EyeRig` turns them into the layers that actually move.
struct MascotEyes: Codable, Equatable {
    struct Eye: Codable, Equatable {
        /// The pupil, normalized to the image.
        var center: CGPoint
        /// Roughly the eye around the pupil, normalized to the image: where `EyeRig` looks
        /// for the pupil's edge when it cuts the pupil out.
        var size: CGSize
    }

    /// The eye on the image's left, then the one on its right (viewer's left and right).
    var left: Eye
    var right: Eye

    /// The Vision revision these were found with. A different revision may place pupils a
    /// little differently, so a stored result is only trusted for the revision that made it.
    var revision: Int
}

/// What's stored next to the custom image: the eyes and where their cut-out layers sit, or
/// why there are none, and the detector revision that decided. A stale revision means
/// "look again".
struct MascotEyesRecord: Codable, Equatable {
    var revision: Int
    var eyes: MascotEyes?
    var rejection: EyeRejection?
    /// Present with `eyes`: the layers themselves are an image file beside this record.
    var rig: EyeRig.Info?

    init(revision: Int, result: Result<MascotEyes, EyeRejection>, rig: EyeRig.Info? = nil) {
        self.revision = revision
        self.rig = rig
        switch result {
        case .success(let eyes): self.eyes = eyes; self.rejection = nil
        case .failure(let reason): self.eyes = nil; self.rejection = reason
        }
    }
}

/// One face as Vision reported it, in image pixels with a top-left origin.
struct FaceCandidate: Equatable {
    var bounds: CGRect
    var confidence: Float
    /// Radians; nil when the revision doesn't report it.
    var yaw: Double?
    var leftPupil: CGPoint?
    var rightPupil: CGPoint?
    /// Bounding boxes of the eye contours, when Vision found them.
    var leftEyeBox: CGRect?
    var rightEyeBox: CGRect?
}

/// Why an image can't have moving eyes. Each reads as the Settings detail line.
enum EyeRejection: String, Error, Equatable, Codable {
    case noFace
    case multipleFaces
    case unsure
    case eyesNotFound
    case eyesTooSmall
    case turnedOrTilted
    case implausible
    case ambiguous
    case cannotSeparate
    case noRoomToMove

    var message: String {
        switch self {
        case .noFace: return "Couldn't find a face or a clear pair of eyes."
        case .multipleFaces: return "More than one face. Pick an image with just one."
        case .unsure: return "The face isn't clear enough to place the eyes."
        case .eyesNotFound: return "Couldn't find both eyes."
        case .eyesTooSmall: return "The eyes are too small to move. Crop closer to the face."
        case .turnedOrTilted: return "The face is turned or tilted. A straight-on face works best."
        case .implausible: return "The eyes found don't look right for this face."
        case .ambiguous: return "Found more than one pair of eye-like spots, so it can't tell which are the eyes."
        case .cannotSeparate: return "Found the eyes, but couldn't cut the pupils out cleanly."
        case .noRoomToMove: return "The pupils fill the eyes, so there's no room for them to move."
        }
    }
}

enum EyeDetectionPolicy {
    /// Vision's face confidence below this is a guess.
    static let minConfidence: Float = 0.6
    /// Faces under this share of the largest face are background faces and ignored, so a
    /// portrait with someone blurred far behind still counts as one face.
    static let backgroundFaceRatio: CGFloat = 0.35
    /// Pupil distance as a share of the image's shorter side. Below it the eyes render
    /// so small that the movement is a pixel or two.
    static let minPupilDistance: CGFloat = 0.12
    /// Head turned further than this (~26°) hides most of one eye.
    static let maxYaw = 0.45
    /// Pupils more than this far apart vertically (per unit of pupil distance) is a tilt.
    static let maxTilt: CGFloat = 0.2
    /// Pupil distance as a share of face width, for a real face. Outside it, Vision has
    /// latched onto something that isn't a pair of eyes.
    static let pupilToFaceWidth: ClosedRange<CGFloat> = 0.25...0.7
    /// Eye opening limits, per unit of pupil distance, so a sloppy contour can't make the
    /// sliding region swallow a brow or a cheek.
    static let eyeWidth: ClosedRange<CGFloat> = 0.3...0.6
    static let eyeHeight: ClosedRange<CGFloat> = 0.12...0.35
    /// When Vision gives a pupil but no contour.
    static let fallbackEyeSize = CGSize(width: 0.42, height: 0.2)

    /// Decides whether `faces`, found in an image of `imageSize` pixels, give one clear pair
    /// of eyes. Deterministic: the same candidates always give the same answer.
    static func evaluate(_ faces: [FaceCandidate], imageSize: CGSize, revision: Int) -> Result<MascotEyes, EyeRejection> {
        guard imageSize.width > 0, imageSize.height > 0 else { return .failure(.noFace) }
        guard let largest = faces.max(by: { area($0.bounds) < area($1.bounds) }) else { return .failure(.noFace) }
        let foreground = faces.filter { area($0.bounds) >= area(largest.bounds) * backgroundFaceRatio }
        guard foreground.count == 1 else { return .failure(.multipleFaces) }

        let face = largest
        guard face.confidence >= minConfidence else { return .failure(.unsure) }
        guard let a = face.leftPupil, let b = face.rightPupil else { return .failure(.eyesNotFound) }

        // Vision's left/right is the subject's; order by x so `left` is always the viewer's.
        let (leftPupil, rightPupil, leftBox, rightBox) = a.x <= b.x
            ? (a, b, face.leftEyeBox, face.rightEyeBox)
            : (b, a, face.rightEyeBox, face.leftEyeBox)

        let dx = rightPupil.x - leftPupil.x
        let dy = rightPupil.y - leftPupil.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return .failure(.implausible) }

        guard distance >= min(imageSize.width, imageSize.height) * minPupilDistance else { return .failure(.eyesTooSmall) }
        if let yaw = face.yaw, abs(yaw) > maxYaw { return .failure(.turnedOrTilted) }
        guard abs(dy) <= distance * maxTilt else { return .failure(.turnedOrTilted) }
        guard face.bounds.width > 0, pupilToFaceWidth.contains(distance / face.bounds.width) else { return .failure(.implausible) }
        guard face.bounds.insetBy(dx: -1, dy: -1).contains(leftPupil),
              face.bounds.insetBy(dx: -1, dy: -1).contains(rightPupil) else { return .failure(.implausible) }

        func eye(_ pupil: CGPoint, _ box: CGRect?) -> MascotEyes.Eye {
            let raw = box.map { CGSize(width: $0.width / distance, height: $0.height / distance) } ?? fallbackEyeSize
            let size = CGSize(
                width: raw.width.clamped(to: eyeWidth) * distance,
                height: raw.height.clamped(to: eyeHeight) * distance
            )
            return MascotEyes.Eye(
                center: CGPoint(x: pupil.x / imageSize.width, y: pupil.y / imageSize.height),
                size: CGSize(width: size.width / imageSize.width, height: size.height / imageSize.height)
            )
        }

        return .success(MascotEyes(left: eye(leftPupil, leftBox), right: eye(rightPupil, rightBox), revision: revision))
    }

    private static func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }

    // MARK: - Photo or drawing

    /// Verdicts that mean "no clear human face here", worth trying as a drawing.
    static let unclearFace: Set<EyeRejection> = [.noFace, .unsure, .eyesNotFound]

    /// Whether a face Vision found is big enough to be what the image is of. Narrower than
    /// this and its pupils could never be `minPupilDistance` apart, whatever else is true
    /// of it. Vision reports such "faces" with full confidence in ornament: a gear at the
    /// top of a steampunk owl that fills the frame, a button, a pattern in a border.
    static func couldBeTheSubject(_ face: FaceCandidate, imageSize: CGSize) -> Bool {
        face.bounds.width * pupilToFaceWidth.upperBound >= min(imageSize.width, imageSize.height) * minPupilDistance
    }

    /// After the photo pass rejected the image: whether to look for drawn eyes instead.
    ///
    /// Yes when Vision saw no clear face, and yes when every face it saw is too small to be
    /// the subject (a stray match must not veto a close-up of a drawn face). No when a
    /// subject-sized face was found and rejected (tilted, two people, eyes that don't fit):
    /// spot-finding on that photo would latch onto nostrils. Eye spots have to be at least
    /// `minPupilDistance` apart, wider than any face dismissed here, so they can't be its
    /// nostrils either.
    static func triesAsDrawing(after rejection: EyeRejection, faces: [FaceCandidate], imageSize: CGSize) -> Bool {
        unclearFace.contains(rejection) || !faces.contains { couldBeTheSubject($0, imageSize: imageSize) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
