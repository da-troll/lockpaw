import CoreGraphics
import Foundation

/// Finds eyes in drawn mascots (cartoons, pixel art, robots, icons), which Vision's face
/// detector, trained on human faces, doesn't see as faces at all.
///
/// A drawn eye is, almost always, a compact spot that stands out from the face around it:
/// a dark dot on a light face or a light dot on a dark one. So: mark every pixel noticeably
/// darker (or lighter) than its neighbourhood, group them into spots, and look for exactly
/// one pair of similar, roundish spots side by side. No model, no randomness: the same
/// pixels always give the same answer. Anything ambiguous is rejected, not guessed.
///
/// Pure, so it's tested on synthetic images. `EyeFinder` only feeds it pixels.
enum DrawnEyes {
    /// Bumped when the rules below change (or when a drawing gets tried: 3 is the hand-off
    /// from the photo pass ignoring stray tiny faces), so stored results are re-checked.
    /// 4: a pupil inside an eyeball counts for more than any other matching pair of spots.
    static let version = 4

    /// Images are scanned at this size; plenty for eyes, trivial to scan.
    static let workingSize = 256

    /// How much darker or lighter than its surroundings (0...1 luminance) a pixel must be.
    static let contrast: Float = 0.12
    /// Neighbourhood radius for "surroundings", as a share of the shorter side.
    static let neighbourhood: CGFloat = 1.0 / 12

    /// An eye's area as a share of the image: below, specks; above, a whole face or panel.
    static let eyeArea: ClosedRange<CGFloat> = 0.0003...0.03
    /// Width over height: dots and ovals, not lines, and not the tall pads of a robot's or
    /// headphone's ears (those run ~0.4).
    static let eyeAspect: ClosedRange<CGFloat> = 0.5...2.5
    /// Share of its bounding box a spot fills: a disc fills ~0.79, a ring or a squiggle far less.
    static let minFill: CGFloat = 0.45
    /// The two eyes of a pair: the bigger no more than this times the smaller.
    static let maxSizeRatio: CGFloat = 2
    /// Eye spacing in eye widths, centre to centre: closer is one smudged feature, further
    /// is two things at the sides of the head (ears, buttons) rather than on the face.
    static let spacing: ClosedRange<CGFloat> = 1.5...6.5
    /// The same, for spots that each sit inside an eyeball, measured in eyeball widths:
    /// big round eyes nearly touch (goggles), and the pupils in them are small and far apart.
    static let nestedSpacing: ClosedRange<CGFloat> = 1.02...6.5
    /// What a spot's eyeball is: a spot of the other tone around it, at least this many
    /// times its area and at most this many times its width (more is the face, not an eye).
    static let eyeballArea: CGFloat = 1.5
    static let eyeballWidth: CGFloat = 8
    /// Added to a pair's score when both spots sit in an eyeball. Nostrils, cheek
    /// highlights and the folds of a paper fox are matching pairs of spots too; a dark
    /// spot inside a light one is what only eyes are.
    static let nestedBonus: CGFloat = 1
    /// A runner-up pair scoring within this share of the best, elsewhere in the image,
    /// makes the answer ambiguous.
    static let ambiguity: CGFloat = 0.9
    /// The area the pupil slides within, in pupil sizes. Drawn faces are usually flat
    /// colour around the eye, so a generous area slides invisibly.
    static let openingScale: CGFloat = 2.4
    /// …but never wider than this share of the eye spacing, so the two never touch.
    static let maxOpeningWidth: CGFloat = 0.8

    /// Luminance (0...1) and opacity per pixel, row by row from the top.
    struct Pixels {
        let width: Int
        let height: Int
        var luminance: [Float]
        var opaque: [Bool]
    }

    struct Spot: Equatable {
        var area: Int
        /// Pixels, top-left origin; `maxX`/`maxY` exclusive.
        var bounds: CGRect
        var centroid: CGPoint
        var isDark: Bool

        var fill: CGFloat { CGFloat(area) / max(1, bounds.width * bounds.height) }
    }

    static func find(in pixels: Pixels, revision: Int) -> Result<MascotEyes, EyeRejection> {
        evaluate(spots(in: pixels), imageSize: CGSize(width: pixels.width, height: pixels.height), revision: revision)
    }

    // MARK: - Spots

    /// Every compact region noticeably darker or lighter than its surroundings.
    static func spots(in pixels: Pixels) -> [Spot] {
        let w = pixels.width, h = pixels.height
        guard w > 2, h > 2, pixels.luminance.count == w * h, pixels.opaque.count == w * h else { return [] }

        // Transparent pixels take the face's average, so a cut-out's edge isn't "contrast".
        let opaqueLuma = zip(pixels.luminance, pixels.opaque).filter(\.1).map(\.0)
        guard !opaqueLuma.isEmpty else { return [] }
        let fillValue = opaqueLuma.reduce(0, +) / Float(opaqueLuma.count)
        let luma = zip(pixels.luminance, pixels.opaque).map { $1 ? $0 : fillValue }

        // Box mean through an integral image.
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(luma[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let r = max(2, Int((CGFloat(min(w, h)) * neighbourhood).rounded()))
        func mean(_ x: Int, _ y: Int) -> Float {
            let x0 = max(0, x - r), x1 = min(w, x + r + 1)
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
            return Float(sum / Double((x1 - x0) * (y1 - y0)))
        }

        var darker = [Bool](repeating: false, count: w * h)
        var lighter = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where pixels.opaque[y * w + x] {
                let delta = luma[y * w + x] - mean(x, y)
                if delta < -contrast { darker[y * w + x] = true }
                if delta > contrast { lighter[y * w + x] = true }
            }
        }

        return components(darker, width: w, height: h, isDark: true)
            + components(lighter, width: w, height: h, isDark: false)
    }

    /// 4-connected regions, skipping any that touch the image edge (eyes don't).
    private static func components(_ mask: [Bool], width w: Int, height h: Int, isDark: Bool) -> [Spot] {
        var seen = [Bool](repeating: false, count: w * h)
        var spots: [Spot] = []
        var stack: [Int] = []

        for start in 0..<(w * h) where mask[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var area = 0, sumX = 0, sumY = 0
            var minX = w, minY = h, maxX = -1, maxY = -1
            var touchesEdge = false

            while let index = stack.popLast() {
                let x = index % w, y = index / w
                area += 1; sumX += x; sumY += y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }

                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let n = ny * w + nx
                    if mask[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }

            guard !touchesEdge, area >= 3 else { continue }
            spots.append(Spot(
                area: area,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                centroid: CGPoint(x: (CGFloat(sumX) / CGFloat(area)) + 0.5, y: (CGFloat(sumY) / CGFloat(area)) + 0.5),
                isDark: isDark
            ))
        }
        return spots
    }

    // MARK: - Pairs

    private struct Pair {
        var left: Spot
        var right: Spot
        var score: CGFloat
        var spacing: CGFloat
    }

    /// Exactly one clear pair of eye-like spots, or a reason there isn't.
    static func evaluate(_ spots: [Spot], imageSize: CGSize, revision: Int) -> Result<MascotEyes, EyeRejection> {
        let imageArea = imageSize.width * imageSize.height
        guard imageArea > 0 else { return .failure(.noFace) }

        let eyeLike = spots.filter { spot in
            let relativeArea = CGFloat(spot.area) / imageArea
            let aspect = spot.bounds.width / max(1, spot.bounds.height)
            return eyeArea.contains(relativeArea) && eyeAspect.contains(aspect) && spot.fill >= minFill
        }

        // The eyeball around a spot, if it has one: the smallest spot of the other tone
        // whose box holds it. Looked for among all spots, not just eye-like ones: an
        // eyeball with a pupil-shaped hole in it is a ring, and rings aren't eye-like.
        func eyeball(of spot: Spot) -> Spot? {
            // Dark in light only. A light spot inside a dark one is the glint on a pupil.
            guard spot.isDark else { return nil }
            return spots.filter { other in
                other.isDark != spot.isDark
                    && other.bounds.insetBy(dx: -1, dy: -1).contains(spot.bounds)
                    && CGFloat(other.area) >= CGFloat(spot.area) * eyeballArea
                    && other.bounds.width <= spot.bounds.width * eyeballWidth
            }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }
        let eyeballs = eyeLike.map(eyeball(of:))

        var pairs: [Pair] = []
        var sawSmallPair = false
        for (i, a) in eyeLike.enumerated() {
            for (j, b) in eyeLike.enumerated() where j > i && a.isDark == b.isDark {
                let (left, right) = a.centroid.x <= b.centroid.x ? (a, b) : (b, a)
                let dx = right.centroid.x - left.centroid.x
                let dy = right.centroid.y - left.centroid.y
                let distance = (dx * dx + dy * dy).squareRoot()
                let averageWidth = (left.bounds.width + right.bounds.width) / 2
                let sizeRatio = CGFloat(max(left.area, right.area)) / CGFloat(max(1, min(left.area, right.area)))

                var nested = false
                var spaced = spacing.contains(distance / max(1, averageWidth))
                if let ballA = eyeballs[i], let ballB = eyeballs[j], ballA != ballB {
                    nested = true
                    let ballWidth = (ballA.bounds.width + ballB.bounds.width) / 2
                    spaced = spaced || nestedSpacing.contains(distance / max(1, ballWidth))
                }
                guard distance > 0,
                      sizeRatio <= maxSizeRatio,
                      abs(dy) <= distance * EyeDetectionPolicy.maxTilt,
                      spaced
                else { continue }
                guard distance >= min(imageSize.width, imageSize.height) * EyeDetectionPolicy.minPupilDistance else {
                    sawSmallPair = true
                    continue
                }

                // Matching sizes and a level line are what make a pair look like eyes;
                // dark wins ties, since pupils are usually the darkest thing on a face.
                let score = (1 / sizeRatio)
                    + (1 - abs(dy) / (distance * EyeDetectionPolicy.maxTilt))
                    + (left.isDark ? 0.05 : 0)
                    + (nested ? nestedBonus : 0)
                pairs.append(Pair(left: left, right: right, score: score, spacing: distance))
            }
        }

        guard let best = pairs.max(by: { $0.score < $1.score }) else {
            return .failure(sawSmallPair ? .eyesTooSmall : .noFace)
        }

        // Another strong pair somewhere else (not the same eyes seen as highlights, say)
        // means we can't tell which are the eyes.
        func isSameEyes(_ other: Pair) -> Bool {
            let reach = max(best.left.bounds.width, best.right.bounds.width, best.left.bounds.height, best.right.bounds.height)
            func near(_ p: CGPoint, _ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= reach }
            return near(other.left.centroid, best.left.centroid) || near(other.right.centroid, best.right.centroid)
                || near(other.left.centroid, best.right.centroid) || near(other.right.centroid, best.left.centroid)
        }
        if pairs.contains(where: { !isSameEyes($0) && $0.score >= best.score * ambiguity }) {
            return .failure(.ambiguous)
        }

        func eye(_ spot: Spot) -> MascotEyes.Eye {
            let width = min(spot.bounds.width * openingScale, best.spacing * maxOpeningWidth)
            let height = spot.bounds.height * openingScale
            return MascotEyes.Eye(
                center: CGPoint(x: spot.centroid.x / imageSize.width, y: spot.centroid.y / imageSize.height),
                size: CGSize(width: width / imageSize.width, height: height / imageSize.height)
            )
        }
        return .success(MascotEyes(left: eye(best.left), right: eye(best.right), revision: revision))
    }
}
