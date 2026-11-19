import CoreGraphics
import Vision

/// Finds the eyes in a custom mascot, in two passes:
///
/// 1. Photos: Vision's face landmarks, which ship with macOS (no model to bundle, the same
///    answer for the same image). Judged by `EyeDetectionPolicy`.
/// 2. Drawings: when Vision sees no clear human face, `DrawnEyes` looks for one pair of
///    eye-like spots. A photo whose face Vision *did* find but rejected (tilted, too small,
///    two people) stays rejected: spot-finding on a photo would latch onto nostrils.
///
/// Run once per image, at install, never per frame.
enum EyeFinder {
    /// Both passes' versions in one number, so a stored result made by either older pass is
    /// re-detected. Vision's revision is pinned so an OS update can't quietly move pupils.
    static let revision = VNDetectFaceLandmarksRequestRevision3 * 100 + DrawnEyes.version

    /// Vision's verdicts that mean "no clear human face here", worth trying as a drawing.
    private static let tryAsDrawing: Set<EyeRejection> = [.noFace, .unsure, .eyesNotFound]

    /// Blocking; tens of milliseconds for a 1024 px image.
    static func find(in image: CGImage) -> Result<MascotEyes, EyeRejection> {
        let photo = findInPhoto(image)
        guard case .failure(let reason) = photo, tryAsDrawing.contains(reason) else { return photo }
        guard let pixels = pixels(of: image) else { return photo }
        return DrawnEyes.find(in: pixels, revision: revision)
    }

    private static func findInPhoto(_ image: CGImage) -> Result<MascotEyes, EyeRejection> {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
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

    /// The image scaled to `DrawnEyes.workingSize` on its longer side, as luminance and opacity.
    private static func pixels(of image: CGImage) -> DrawnEyes.Pixels? {
        let scale = min(1, CGFloat(DrawnEyes.workingSize) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Rows come out top first, matching `DrawnEyes.Pixels`.
        var luminance = [Float](repeating: 0, count: width * height)
        var opaque = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let a = Float(rgba[i * 4 + 3]) / 255
            guard a >= 0.5 else { continue }
            let r = Float(rgba[i * 4]) / 255 / a
            let g = Float(rgba[i * 4 + 1]) / 255 / a
            let b = Float(rgba[i * 4 + 2]) / 255 / a
            luminance[i] = min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            opaque[i] = true
        }
        return DrawnEyes.Pixels(width: width, height: height, luminance: luminance, opaque: opaque)
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
