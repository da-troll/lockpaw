import CoreGraphics
import Vision

/// Finds the eyes in a custom mascot with Vision's face landmarks, which ship with macOS:
/// no model to bundle, nothing downloaded, the same answer for the same image. Every
/// judgment call (one face? straight on? big enough?) is `EyeDetectionPolicy`'s; this
/// only translates Vision's coordinates.
///
/// Run once per image, at install, never per frame.
enum EyeFinder {
    /// Pinned so an OS update can't quietly move stored pupils: a record made with another
    /// revision is re-detected.
    static let revision = VNDetectFaceLandmarksRequestRevision3

    /// Blocking; a 1024 px image takes tens of milliseconds.
    static func find(in image: CGImage) -> Result<MascotEyes, EyeRejection> {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = revision
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(.noFace)
        }
        let size = CGSize(width: image.width, height: image.height)
        let faces = (request.results ?? []).map { candidate(from: $0, imageSize: size) }
        return EyeDetectionPolicy.evaluate(faces, imageSize: size, revision: revision)
    }

    /// Vision speaks normalized, bottom-left-origin coordinates; the policy wants pixels
    /// with a top-left origin, like the image as drawn.
    private static func candidate(from face: VNFaceObservation, imageSize: CGSize) -> FaceCandidate {
        func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: imageSize.height - point.y) }

        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(imageSize.width), Int(imageSize.height))
        let bounds = CGRect(x: box.minX, y: imageSize.height - box.maxY, width: box.width, height: box.height)

        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region, region.pointCount > 0 else { return [] }
            return region.pointsInImage(imageSize: imageSize).map(flipped)
        }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let pts = points(region)
            guard !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }
        func bounding(_ region: VNFaceLandmarkRegion2D?) -> CGRect? {
            let pts = points(region)
            guard pts.count >= 3,
                  let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                  let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max()
            else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        let landmarks = face.landmarks
        return FaceCandidate(
            bounds: bounds,
            confidence: face.confidence,
            yaw: face.yaw?.doubleValue,
            leftPupil: center(landmarks?.leftPupil),
            rightPupil: center(landmarks?.rightPupil),
            leftEyeBox: bounding(landmarks?.leftEye),
            rightEyeBox: bounding(landmarks?.rightEye)
        )
    }
}
