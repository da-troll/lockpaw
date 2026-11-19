import CoreGraphics
import Foundation

/// Splits a custom mascot's eyes into layers, the way a hand-made 2D rig (Live2D and the
/// like) is built: the pupil is cut out and is the only thing that moves, the hole it
/// leaves is painted in from the eye around it, and the pupil is only ever drawn inside
/// the eye. Lids, rims and sockets stay the original pixels, so there is no cut edge to see.
///
/// The first version slid a soft-edged patch of the whole eye, rim and all; the shifted rim
/// showed through as a doubled outline on every image tried.
///
/// Built once per image, at install, from the eyes `EyeFinder` placed. Pure and
/// deterministic: pixels in, layers out, no model. Anything it can't separate cleanly is
/// rejected, and that image simply has no moving eyes.
enum EyeRig {
    /// Bumped when the rules below change, so a stored rig is rebuilt.
    static let version = 1

    /// Each eye is worked on in a window this many eye-spacings wide, centred on the pupil:
    /// just under half, so the two windows never overlap.
    static let windowShare: CGFloat = 0.48
    /// The pupil's area as a share of its window: below, a speck; above, not a pupil.
    static let pupilShare: ClosedRange<CGFloat> = 0.002...0.45
    /// Share of its bounding box a pupil fills (a disc fills ~0.79).
    static let minPupilFill: CGFloat = 0.55
    /// Where the pupil's edge is looked for, from the even split between its tone and the
    /// eye's (1) toward the pupil's own tone, tried in order until the patch is a blob.
    static let pupilToneSteps: [Float] = [1, 0.75, 0.55, 0.4, 0.28]
    /// The hole painted over is the pupil grown until the eye around it stops changing: a
    /// pupil's edge is soft, and a fringe or shadow left on the plate shows as a ghost ring
    /// where the pupil used to be. At least 2 px, at most this share of the radius.
    static let maxHoleGrow: CGFloat = 0.35
    /// "Stops changing": successive one-pixel rings differ by less than this (0...255).
    static let holeSettled: Float = 1.2
    /// The pupil keeps this share of its radius clear of the edge of the eye at full travel.
    static let rimMargin: CGFloat = 0.1
    /// Travel is never more than this share of the pupil's width and height, however much
    /// room there is: on a flat face (dot eyes) the "eye" is the whole face.
    static let maxTravel = CGSize(width: 0.5, height: 0.4)
    /// Less sideways room than this share of the pupil's width, both ways together, is not
    /// worth moving for.
    static let minTravel: CGFloat = 0.12
    /// How far a pixel's colour may sit from the colour around the pupil and still be "the
    /// eye", in units of that colour's own spread, within these 0...255 limits.
    static let eyeTolerance: ClosedRange<Float> = 34...84
    static let eyeToleranceSpread: Float = 3.2
    /// Above this spread (0...255) the eye around the pupil is patterned, not plain.
    static let texturedSpread: Float = 36

    /// Straight (not premultiplied) RGBA, rows from the top.
    struct Bitmap: Equatable {
        let width: Int
        let height: Int
        var rgba: [UInt8]

        init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width
            self.height = height
            self.rgba = rgba
        }

        init(width: Int, height: Int) {
            self.init(width: width, height: height, rgba: [UInt8](repeating: 0, count: max(0, width * height * 4)))
        }
    }

    /// How far the pupils may move from where they were drawn, each way, as a share of the
    /// image's width (left, right) or height (up, down). The same for both eyes.
    struct Travel: Codable, Equatable {
        var left: CGFloat
        var right: CGFloat
        var up: CGFloat
        var down: CGFloat
    }

    /// What's stored with the layers.
    struct Info: Codable, Equatable {
        var version: Int
        /// Where the layers sit in the image, normalized, top-left origin.
        var rect: CGRect
        var travel: Travel
    }

    /// Three images of the same size, covering `info.rect` of the mascot.
    struct Layers: Equatable {
        /// Opaque only where a pupil was: the eye painted in underneath it.
        var plate: Bitmap
        /// The two pupils, cut out, on transparent ground. This is the layer that moves.
        var pupils: Bitmap
        /// Opaque where a pupil may be drawn: the eyes themselves. This one stays put.
        var clip: Bitmap
        var info: Info
    }

    /// How far to slide the pupil layer, in points, for a gaze in -1...1 on each axis
    /// (+x right, +y down). The gaze is held to the unit circle first: the room measured is
    /// straight sideways and straight up and down, and a round eye has less on the diagonal.
    static func offset(gaze: CGPoint, travel: Travel, fittedSize: CGSize) -> CGSize {
        var x = gaze.x, y = gaze.y
        let length = (x * x + y * y).squareRoot()
        if length > 1 { x /= length; y /= length }
        return CGSize(
            width: x * (x >= 0 ? travel.right : travel.left) * fittedSize.width,
            height: y * (y >= 0 ? travel.down : travel.up) * fittedSize.height
        )
    }

    // MARK: - Build

    static func build(image: Bitmap, eyes: MascotEyes) -> Result<Layers, EyeRejection> {
        let w = image.width, h = image.height
        guard w > 8, h > 8, image.rgba.count == w * h * 4 else { return .failure(.cannotSeparate) }

        let centers = [eyes.left, eyes.right].map {
            CGPoint(x: $0.center.x * CGFloat(w), y: $0.center.y * CGFloat(h))
        }
        let spacing = hypot(centers[1].x - centers[0].x, centers[1].y - centers[0].y)
        guard spacing >= 8 else { return .failure(.cannotSeparate) }

        var parts: [EyeParts] = []
        for (eye, center) in zip([eyes.left, eyes.right], centers) {
            let hint = CGSize(width: eye.size.width * CGFloat(w), height: eye.size.height * CGFloat(h))
            switch separate(image, center: center, spacing: spacing, hint: hint) {
            case .success(let found): parts.append(found)
            case .failure(let reason): return .failure(reason)
            }
        }

        // Both eyes move together, so each direction gets what the tighter eye allows.
        let px = Travel(
            left: parts.map(\.travel.left).min() ?? 0,
            right: parts.map(\.travel.right).min() ?? 0,
            up: parts.map(\.travel.up).min() ?? 0,
            down: parts.map(\.travel.down).min() ?? 0
        )
        let pupilWidth = parts.map { CGFloat($0.pupilBounds.width) }.min() ?? 0
        guard px.left + px.right >= max(2, pupilWidth * minTravel) else { return .failure(.noRoomToMove) }

        // One rect around everything that is drawn.
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for part in parts {
            x0 = min(x0, part.window.x + part.used.minX)
            y0 = min(y0, part.window.y + part.used.minY)
            x1 = max(x1, part.window.x + part.used.maxX)
            y1 = max(y1, part.window.y + part.used.maxY)
        }
        x0 = max(0, x0 - 2); y0 = max(0, y0 - 2); x1 = min(w, x1 + 2); y1 = min(h, y1 + 2)
        let cw = x1 - x0, ch = y1 - y0
        guard cw > 0, ch > 0 else { return .failure(.cannotSeparate) }

        var plate = Bitmap(width: cw, height: ch)
        var pupils = Bitmap(width: cw, height: ch)
        var clipAlpha = [Float](repeating: 0, count: cw * ch)

        for part in parts {
            let win = part.window
            for y in 0..<win.h {
                for x in 0..<win.w {
                    let i = y * win.w + x
                    let cx = win.x + x - x0, cy = win.y + y - y0
                    guard cx >= 0, cy >= 0, cx < cw, cy < ch else { continue }
                    let o = (cy * cw + cx) * 4
                    if part.hole[i] {
                        plate.rgba[o] = toByte(part.fill[i * 3])
                        plate.rgba[o + 1] = toByte(part.fill[i * 3 + 1])
                        plate.rgba[o + 2] = toByte(part.fill[i * 3 + 2])
                        plate.rgba[o + 3] = 255
                    }
                    let a = part.spriteAlpha[i]
                    if a > 0 {
                        pupils.rgba[o] = toByte(part.sprite[i * 3])
                        pupils.rgba[o + 1] = toByte(part.sprite[i * 3 + 1])
                        pupils.rgba[o + 2] = toByte(part.sprite[i * 3 + 2])
                        pupils.rgba[o + 3] = toByte(a * 255)
                    }
                    if part.region[i] { clipAlpha[cy * cw + cx] = 1 }
                }
            }
        }

        // A soft one-pixel edge on the clip, so a pupil at the rim isn't cut with a jagged line.
        var clip = Bitmap(width: cw, height: ch)
        for y in 0..<ch {
            for x in 0..<cw {
                var sum: Float = 0, n: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
                        sum += clipAlpha[ny * cw + nx]; n += 1
                    }
                }
                let o = (y * cw + x) * 4
                clip.rgba[o] = 255; clip.rgba[o + 1] = 255; clip.rgba[o + 2] = 255
                clip.rgba[o + 3] = toByte(sum / max(1, n) * 255)
            }
        }

        let info = Info(
            version: version,
            rect: CGRect(
                x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h),
                width: CGFloat(cw) / CGFloat(w), height: CGFloat(ch) / CGFloat(h)
            ),
            travel: Travel(
                left: px.left / CGFloat(w), right: px.right / CGFloat(w),
                up: px.up / CGFloat(h), down: px.down / CGFloat(h)
            )
        )
        return .success(Layers(plate: plate, pupils: pupils, clip: clip, info: info))
    }

    // MARK: - One eye

    private struct Window { var x: Int; var y: Int; var w: Int; var h: Int }

    private struct EyeParts {
        var window: Window
        /// Window-local masks and colours (RGB floats, 0...255).
        var hole: [Bool]
        var region: [Bool]
        var fill: [Float]
        var sprite: [Float]
        var spriteAlpha: [Float]
        /// Window-local bounds of everything drawn (`max` exclusive).
        var used: (minX: Int, minY: Int, maxX: Int, maxY: Int)
        var pupilBounds: (width: Int, height: Int)
        /// Pixels.
        var travel: Travel
    }

    private static func separate(_ image: Bitmap, center: CGPoint, spacing: CGFloat, hint: CGSize) -> Result<EyeParts, EyeRejection> {
        let half = max(6, Int((spacing * windowShare).rounded()))
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let wx0 = max(0, cx - half), wy0 = max(0, cy - half)
        let wx1 = min(image.width, cx + half + 1), wy1 = min(image.height, cy + half + 1)
        let wide = Window(x: wx0, y: wy0, w: wx1 - wx0, h: wy1 - wy0)
        let lx = cx - wx0, ly = cy - wy0
        guard wide.w > 8, wide.h > 8, lx >= 0, ly >= 0, lx < wide.w, ly < wide.h else { return .failure(.cannotSeparate) }
        let wideCount = wide.w * wide.h

        // The window's pixels as floats.
        var wideRGB = [Float](repeating: 0, count: wideCount * 3)
        var wideOpaque = [Bool](repeating: false, count: wideCount)
        var wideLuma = [Float](repeating: 0, count: wideCount)
        for y in 0..<wide.h {
            for x in 0..<wide.w {
                let s = ((wy0 + y) * image.width + wx0 + x) * 4
                let i = y * wide.w + x
                let r = Float(image.rgba[s]), g = Float(image.rgba[s + 1]), b = Float(image.rgba[s + 2])
                wideRGB[i * 3] = r; wideRGB[i * 3 + 1] = g; wideRGB[i * 3 + 2] = b
                wideOpaque[i] = image.rgba[s + 3] >= 128
                wideLuma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        guard wideOpaque[ly * wide.w + lx] else { return .failure(.cannotSeparate) }

        // 1. The pupil: split the area the detector marked into its two tones, and take the
        //    connected patch of the centre's tone.
        let hx = max(3, Int((hint.width / 2).rounded())), hy = max(3, Int((hint.height / 2).rounded()))
        var histogram = [Int](repeating: 0, count: 256)
        for y in max(0, ly - hy)...min(wide.h - 1, ly + hy) {
            for x in max(0, lx - hx)...min(wide.w - 1, lx + hx) where wideOpaque[y * wide.w + x] {
                histogram[Int(min(255, max(0, wideLuma[y * wide.w + x])))] += 1
            }
        }
        guard let threshold = otsu(histogram) else { return .failure(.cannotSeparate) }

        var seedSum: Float = 0, seedCount: Float = 0
        let sr = max(1, min(hx, hy) / 6)
        for y in max(0, ly - sr)...min(wide.h - 1, ly + sr) {
            for x in max(0, lx - sr)...min(wide.w - 1, lx + sr) where wideOpaque[y * wide.w + x] {
                seedSum += wideLuma[y * wide.w + x]; seedCount += 1
            }
        }
        let seedTone = seedSum / max(1, seedCount)
        let pupilIsDark = seedTone < threshold

        // The two-tone split is the pupil's true edge, but on a textured eye (dark lines
        // running through an iris) pupil-toned pixels can lead all the way out of the eye.
        // So when the patch isn't a compact blob, ask for a tone closer to the pupil's own.
        var found: (pupil: [Bool], seed: Int, bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int), cut: Float)?
        for share in pupilToneSteps {
            let cut = seedTone + (threshold - seedTone) * share
            func isTone(_ i: Int) -> Bool { wideOpaque[i] && ((wideLuma[i] < cut) == pupilIsDark) }

            // The exact centre may sit on a highlight; start from the nearest pupil-toned pixel.
            var seed: Int?
            search: for reach in 0...max(1, sr * 2) {
                for y in max(0, ly - reach)...min(wide.h - 1, ly + reach) {
                    for x in max(0, lx - reach)...min(wide.w - 1, lx + reach) where isTone(y * wide.w + x) {
                        seed = y * wide.w + x
                        break search
                    }
                }
            }
            guard let seed else { continue }
            var candidate = flood(from: [seed], width: wide.w, height: wide.h, accept: isTone)
            guard !touchesEdge(candidate, width: wide.w, height: wide.h) else { continue }
            fillHoles(&candidate, width: wide.w, height: wide.h) // highlights are part of the pupil
            guard let cb = bounds(of: candidate, width: wide.w, height: wide.h) else { continue }
            let area = candidate.reduce(0) { $0 + ($1 ? 1 : 0) }
            let cw = cb.maxX - cb.minX, ch = cb.maxY - cb.minY
            guard pupilShare.contains(CGFloat(area) / CGFloat(wideCount)),
                  CGFloat(area) / CGFloat(cw * ch) >= minPupilFill,
                  cw >= 4, ch >= 4, cw <= ch * 3, ch <= cw * 3
            else { continue }
            found = (candidate, seed, cb, cut)
            break
        }
        guard let found else { return .failure(.cannotSeparate) }
        // The rest only concerns the pupil and as far as it could ever travel, so carry on
        // in a window just that big: a quarter of the pixels, and nothing lost.
        let wideBounds = found.bounds
        let pw = wideBounds.maxX - wideBounds.minX, ph = wideBounds.maxY - wideBounds.minY
        let radius = CGFloat(min(pw, ph)) / 2
        let capX = max(1, Int((CGFloat(pw) * maxTravel.width).rounded()))
        let capY = max(1, Int((CGFloat(ph) * maxTravel.height).rounded()))
        let slack = Int((radius * (maxHoleGrow + rimMargin)).rounded()) + 8
        let kx0 = max(0, wideBounds.minX - capX - slack), kx1 = min(wide.w, wideBounds.maxX + capX + slack)
        let ky0 = max(0, wideBounds.minY - capY - slack), ky1 = min(wide.h, wideBounds.maxY + capY + slack)
        let win = Window(x: wide.x + kx0, y: wide.y + ky0, w: kx1 - kx0, h: ky1 - ky0)
        let count = win.w * win.h
        var rgb = [Float](repeating: 0, count: count * 3)
        var opaque = [Bool](repeating: false, count: count)
        var luma = [Float](repeating: 0, count: count)
        var pupil = [Bool](repeating: false, count: count)
        for y in 0..<win.h {
            for x in 0..<win.w {
                let from = (ky0 + y) * wide.w + kx0 + x, to = y * win.w + x
                for channel in 0..<3 { rgb[to * 3 + channel] = wideRGB[from * 3 + channel] }
                opaque[to] = wideOpaque[from]
                luma[to] = wideLuma[from]
                pupil[to] = found.pupil[from]
            }
        }
        let seed = (found.seed / wide.w - ky0) * win.w + (found.seed % wide.w - kx0)
        func isPupilTone(_ i: Int) -> Bool { opaque[i] && ((luma[i] < found.cut) == pupilIsDark) }

        // 2. The hole to paint over: the pupil and its soft fringe.
        let maxGrow = max(4, Int((radius * maxHoleGrow).rounded()))
        let fromPupil = distances(to: pupil, width: win.w, height: win.h)
        var ringSum = [Float](repeating: 0, count: maxGrow + 3)
        var ringCount = [Float](repeating: 0, count: maxGrow + 3)
        for i in 0..<count where opaque[i] && fromPupil[i] > 0 {
            let k = Int(fromPupil[i].rounded(.up)) - 1
            if k < ringSum.count { ringSum[k] += luma[i]; ringCount[k] += 1 }
        }
        var ringLuma = [Float](repeating: 0, count: maxGrow + 3)
        for k in 0..<ringLuma.count {
            ringLuma[k] = ringCount[k] > 0 ? ringSum[k] / ringCount[k] : (k > 0 ? ringLuma[k - 1] : 0)
        }
        var grow = maxGrow
        for k in 2..<maxGrow
        where abs(ringLuma[k + 1] - ringLuma[k]) < holeSettled && abs(ringLuma[k + 2] - ringLuma[k]) < holeSettled * 2 {
            grow = k
            break
        }
        let hole = fromPupil.map { $0 <= Float(grow) }
        // If what the hole grew out to is as dark (or light) as the pupil, the pupil sits
        // right against the eye's outline: there is no eye around it to move in, and too
        // little of it to learn its colour from.
        guard (ringLuma[grow] < found.cut) != pupilIsDark else { return .failure(.noRoomToMove) }
        guard !touchesEdge(hole, width: win.w, height: win.h) else { return .failure(.cannotSeparate) }

        // 3. The eye around it: everything connected to the pupil's surroundings that is
        //    about their colour. Judged on a lightly blurred copy so texture doesn't fray it.
        //    The hole is left out of the blur, or the pupil's dark would bleed into it.
        let soft = blurred(rgb, width: win.w, height: win.h, radius: max(1, Int((radius * 0.08).rounded())), skipping: hole)
        //    The colour is learnt in two steps, because the eye may be only a few pixels wide
        //    around a big pupil: first from a thin ring hugging the hole, then from whatever
        //    of that colour lies within a wider band. A wide band taken blind would average
        //    in the outline and the face beyond it, and the "eye" would then include them.
        let thinRing = dilated(hole, by: 3, width: win.w, height: win.h)
        var nearest: [Int] = []
        for i in 0..<count where thinRing[i] && !hole[i] && opaque[i] { nearest.append(i) }
        guard nearest.count >= 12 else { return .failure(.cannotSeparate) }
        var nearMean = [Float](repeating: 0, count: 3)
        for i in nearest { for c in 0..<3 { nearMean[c] += soft[i * 3 + c] } }
        for c in 0..<3 { nearMean[c] /= Float(nearest.count) }
        var nearVariance: Float = 0
        for i in nearest { nearVariance += distanceSquared(soft, i, nearMean) }
        let nearSpread = (nearVariance / Float(nearest.count)).squareRoot()
        let nearTolerance = min(max(nearSpread * eyeToleranceSpread, eyeTolerance.lowerBound), eyeTolerance.upperBound)

        let band = dilated(hole, by: max(3, Int((radius * 0.3).rounded())), width: win.w, height: win.h)
        let reached = flood(from: nearest, width: win.w, height: win.h) {
            band[$0] && !hole[$0] && opaque[$0] && distanceSquared(soft, $0, nearMean) <= nearTolerance * nearTolerance
        }
        var ring: [Int] = []
        for i in 0..<count where reached[i] { ring.append(i) }
        guard ring.count >= 12 else { return .failure(.cannotSeparate) }

        func tone(of image: [Float]) -> (mean: [Float], spread: Float) {
            var mean = [Float](repeating: 0, count: 3)
            for i in ring { for c in 0..<3 { mean[c] += image[i * 3 + c] } }
            for c in 0..<3 { mean[c] /= Float(ring.count) }
            var variance: Float = 0
            for i in ring { variance += distanceSquared(image, i, mean) }
            return (mean, (variance / Float(ring.count)).squareRoot())
        }
        // A patterned eye (the blades of an owl's iris) is one colour only from a distance:
        // judge it on a much heavier blur, which is what "from a distance" means.
        var judged = soft
        var (mean, spread) = tone(of: soft)
        if spread > texturedSpread {
            judged = blurred(rgb, width: win.w, height: win.h, radius: max(2, Int((radius * 0.3).rounded())), skipping: hole)
            (mean, spread) = tone(of: judged)
        }
        let tolerance = min(max(spread * eyeToleranceSpread, eyeTolerance.lowerBound), eyeTolerance.upperBound)
        let toleranceSquared = tolerance * tolerance

        // Never anything as dark (or light) as the pupil itself: that is the eye's outline,
        // a lid or a lash, and the pupil must not be able to slide over it. Read off the
        // same blurred copy, so a hairline in a patterned iris isn't taken for an outline.
        func isEyeTone(_ i: Int) -> Bool {
            guard opaque[i], distanceSquared(judged, i, mean) <= toleranceSquared else { return false }
            let tone = 0.2126 * judged[i * 3] + 0.7152 * judged[i * 3 + 1] + 0.0722 * judged[i * 3 + 2]
            return (tone < found.cut) != pupilIsDark
        }
        let seeds = ring.filter(isEyeTone)
        guard seeds.count >= ring.count / 3 else { return .failure(.cannotSeparate) }

        var region = flood(from: seeds, width: win.w, height: win.h) { hole[$0] || isEyeTone($0) }
        for i in 0..<count where hole[i] { region[i] = true }
        fillHoles(&region, width: win.w, height: win.h)
        // Opening: drop thin leaks through a gap in the eye's outline, keep the body.
        let thin = max(1, Int((radius * 0.12).rounded()))
        let opened = dilated(eroded(region, by: thin, width: win.w, height: win.h), by: thin, width: win.w, height: win.h)
        for i in 0..<count where !opened[i] { region[i] = false } // opening only ever removes
        for i in 0..<count where hole[i] { region[i] = true }
        region = flood(from: [seed], width: win.w, height: win.h) { region[$0] }
        fillHoles(&region, width: win.w, height: win.h)

        // 4. Room to move: how far the pupil, with a margin, can slide each way and stay
        //    wholly inside the eye.
        let margin = max(1, Int((radius * rimMargin).rounded()))
        let body = dilated(pupil, by: margin, width: win.w, height: win.h)
        // The eye has no holes, so if the pupil's outline fits, all of it does.
        var bodyPixels: [(x: Int, y: Int)] = []
        for y in 0..<win.h {
            for x in 0..<win.w where body[y * win.w + x] {
                let edge = x == 0 || y == 0 || x == win.w - 1 || y == win.h - 1
                    || !body[y * win.w + x - 1] || !body[y * win.w + x + 1]
                    || !body[(y - 1) * win.w + x] || !body[(y + 1) * win.w + x]
                if edge { bodyPixels.append((x, y)) }
            }
        }
        func room(dx: Int, dy: Int, limit: Int) -> Int {
            var reach = 0
            for step in 1...max(1, limit) {
                let fits = bodyPixels.allSatisfy { p in
                    let x = p.x + dx * step, y = p.y + dy * step
                    return x >= 0 && y >= 0 && x < win.w && y < win.h && region[y * win.w + x]
                }
                if !fits { break }
                reach = step
            }
            return reach
        }
        let travel = Travel(
            left: CGFloat(room(dx: -1, dy: 0, limit: capX)),
            right: CGFloat(room(dx: 1, dy: 0, limit: capX)),
            up: CGFloat(room(dx: 0, dy: -1, limit: capY)),
            down: CGFloat(room(dx: 0, dy: 1, limit: capY))
        )

        // 5. The plate: the hole painted in from the eye around it. Each pixel is a blend
        //    of the colours just outside the hole, the nearer ones counting for more, so
        //    shading runs across the fill the way it runs across the eye.
        let sampleBand = dilated(hole, by: 3, width: win.w, height: win.h)
        var samples: [Int] = []
        for i in 0..<count where sampleBand[i] && !hole[i] && opaque[i] && region[i] { samples.append(i) }
        if samples.count < 16 {
            samples = []
            for i in 0..<count where sampleBand[i] && !hole[i] && opaque[i] { samples.append(i) }
        }
        guard !samples.isEmpty else { return .failure(.cannotSeparate) }
        let stride = max(1, samples.count / 120)
        let chosen = Swift.stride(from: 0, to: samples.count, by: stride).map { samples[$0] }
        let sx = chosen.map { Float($0 % win.w) }, sy = chosen.map { Float($0 / win.w) }

        var fill = [Float](repeating: 0, count: count * 3)
        for y in 0..<win.h {
            for x in 0..<win.w where hole[y * win.w + x] {
                var r: Float = 0, g: Float = 0, b: Float = 0, total: Float = 0
                for k in 0..<chosen.count {
                    let dx = sx[k] - Float(x), dy = sy[k] - Float(y)
                    let d2 = dx * dx + dy * dy + 0.5
                    let weight = 1 / (d2 * d2.squareRoot())
                    let s = chosen[k] * 3
                    r += soft[s] * weight; g += soft[s + 1] * weight; b += soft[s + 2] * weight
                    total += weight
                }
                let i = (y * win.w + x) * 3
                fill[i] = r / total; fill[i + 1] = g / total; fill[i + 2] = b / total
            }
        }

        // 6. The pupil sprite. Inside, the original pixels. Along the edge, each pixel is
        //    a mix of pupil and eye: work out how much pupil, and take the eye back out.
        let inner = eroded(pupil, by: 2, width: win.w, height: win.h)
        var core = [Float](repeating: 0, count: 3)
        var coreCount: Float = 0
        for i in 0..<count where inner[i] && isPupilTone(i) {
            for c in 0..<3 { core[c] += rgb[i * 3 + c] }
            coreCount += 1
        }
        if coreCount == 0 {
            for i in 0..<count where pupil[i] {
                for c in 0..<3 { core[c] += rgb[i * 3 + c] }
                coreCount += 1
            }
        }
        for c in 0..<3 { core[c] /= max(1, coreCount) }

        var sprite = [Float](repeating: 0, count: count * 3)
        var spriteAlpha = [Float](repeating: 0, count: count)
        for i in 0..<count where hole[i] {
            if inner[i] {
                for c in 0..<3 { sprite[i * 3 + c] = rgb[i * 3 + c] }
                spriteAlpha[i] = 1
                continue
            }
            var along: Float = 0, span: Float = 0
            for c in 0..<3 {
                let toCore = core[c] - fill[i * 3 + c]
                along += (rgb[i * 3 + c] - fill[i * 3 + c]) * toCore
                span += toCore * toCore
            }
            let alpha = span > 1 ? min(1, max(0, along / span)) : (pupil[i] ? 1 : 0)
            guard alpha > 0.03 else { continue }
            for c in 0..<3 {
                let unmixed = fill[i * 3 + c] + (rgb[i * 3 + c] - fill[i * 3 + c]) / alpha
                sprite[i * 3 + c] = min(255, max(0, unmixed))
            }
            spriteAlpha[i] = alpha
        }

        guard let rb = bounds(of: region, width: win.w, height: win.h) else { return .failure(.cannotSeparate) }
        return .success(EyeParts(
            window: win, hole: hole, region: region, fill: fill, sprite: sprite, spriteAlpha: spriteAlpha,
            used: rb, pupilBounds: (pw, ph), travel: travel
        ))
    }

    // MARK: - Pixels

    private static func toByte(_ value: Float) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }

    private static func distanceSquared(_ rgb: [Float], _ i: Int, _ to: [Float]) -> Float {
        let r = rgb[i * 3] - to[0], g = rgb[i * 3 + 1] - to[1], b = rgb[i * 3 + 2] - to[2]
        return r * r + g * g + b * b
    }

    /// The threshold that best splits a histogram into two tones; nil when it has only one.
    static func otsu(_ histogram: [Int]) -> Float? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBelow = 0.0, countBelow = 0, best = -1.0, bestLevel = -1
        for level in 0..<256 {
            countBelow += histogram[level]
            if countBelow == 0 { continue }
            let countAbove = total - countBelow
            if countAbove == 0 { break }
            sumBelow += Double(level * histogram[level])
            let meanBelow = sumBelow / Double(countBelow)
            let meanAbove = (sumAll - sumBelow) / Double(countAbove)
            let between = Double(countBelow) * Double(countAbove) * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if between > best { best = between; bestLevel = level }
        }
        guard bestLevel >= 0 else { return nil }
        // The darker tone is every value in bins 0...bestLevel, so the split is that bin's
        // upper edge. Half a level lower, a value of 43.6 counted as dark here and light
        // everywhere the threshold was used.
        return Float(bestLevel) + 1
    }

    /// 4-connected fill from `seeds` over pixels `accept` allows.
    private static func flood(from seeds: [Int], width w: Int, height h: Int, accept: (Int) -> Bool) -> [Bool] {
        var mask = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for s in seeds where !mask[s] && accept(s) { mask[s] = true; stack.append(s) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0, !mask[i - 1], accept(i - 1) { mask[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, !mask[i + 1], accept(i + 1) { mask[i + 1] = true; stack.append(i + 1) }
            if y > 0, !mask[i - w], accept(i - w) { mask[i - w] = true; stack.append(i - w) }
            if y < h - 1, !mask[i + w], accept(i + w) { mask[i + w] = true; stack.append(i + w) }
        }
        return mask
    }

    /// Fills everything the outside can't reach.
    private static func fillHoles(_ mask: inout [Bool], width w: Int, height h: Int) {
        var border: [Int] = []
        for x in 0..<w { border.append(x); border.append((h - 1) * w + x) }
        for y in 0..<h { border.append(y * w); border.append(y * w + w - 1) }
        let current = mask
        let outside = flood(from: border, width: w, height: h) { !current[$0] }
        for i in 0..<(w * h) where !outside[i] { mask[i] = true }
    }

    private static func touchesEdge(_ mask: [Bool], width w: Int, height h: Int) -> Bool {
        for x in 0..<w where mask[x] || mask[(h - 1) * w + x] { return true }
        for y in 0..<h where mask[y * w] || mask[y * w + w - 1] { return true }
        return false
    }

    private static func bounds(of mask: [Bool], width w: Int, height h: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX + 1, maxY + 1)
    }

    /// How far each pixel is from the mask, in pixels (0 inside it). Two sweeps, counting a
    /// diagonal step as √2: close to the true distance, and one pass however far it reaches.
    private static func distances(to mask: [Bool], width w: Int, height h: Int) -> [Float] {
        let far = Float(w + h) * 2
        let diagonal: Float = 1.41421356
        var d = mask.map { $0 ? Float(0) : far }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var best = d[i]
                if best == 0 { continue }
                if x > 0 { best = min(best, d[i - 1] + 1) }
                if y > 0 {
                    best = min(best, d[i - w] + 1)
                    if x > 0 { best = min(best, d[i - w - 1] + diagonal) }
                    if x < w - 1 { best = min(best, d[i - w + 1] + diagonal) }
                }
                d[i] = best
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                var best = d[i]
                if best == 0 { continue }
                if x < w - 1 { best = min(best, d[i + 1] + 1) }
                if y < h - 1 {
                    best = min(best, d[i + w] + 1)
                    if x < w - 1 { best = min(best, d[i + w + 1] + diagonal) }
                    if x > 0 { best = min(best, d[i + w - 1] + diagonal) }
                }
                d[i] = best
            }
        }
        return d
    }

    /// Grows a mask by `steps` pixels, evenly all round.
    private static func dilated(_ mask: [Bool], by steps: Int, width w: Int, height h: Int) -> [Bool] {
        guard steps > 0 else { return mask }
        let reach = Float(steps) + 0.01
        return distances(to: mask, width: w, height: h).map { $0 <= reach }
    }

    private static func eroded(_ mask: [Bool], by steps: Int, width w: Int, height h: Int) -> [Bool] {
        dilated(mask.map { !$0 }, by: steps, width: w, height: h).map { !$0 }
    }

    /// Box blur of an RGB float image that ignores the pixels in `skipping`: they add
    /// nothing to their neighbours (and keep their own colour). Running sums, so the cost
    /// doesn't grow with the radius.
    private static func blurred(_ rgb: [Float], width w: Int, height h: Int, radius: Int, skipping: [Bool]) -> [Float] {
        guard radius > 0 else { return rgb }
        // Four channels: r, g, b and how many pixels went in.
        var rows = [Float](repeating: 0, count: w * h * 4)
        var prefix = [Float](repeating: 0, count: (max(w, h) + 1) * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let keep: Float = skipping[i] ? 0 : 1
                for c in 0..<3 { prefix[(x + 1) * 4 + c] = prefix[x * 4 + c] + rgb[i * 3 + c] * keep }
                prefix[(x + 1) * 4 + 3] = prefix[x * 4 + 3] + keep
            }
            for x in 0..<w {
                let lo = max(0, x - radius), hi = min(w - 1, x + radius) + 1
                for c in 0..<4 { rows[(y * w + x) * 4 + c] = prefix[hi * 4 + c] - prefix[lo * 4 + c] }
            }
        }
        var out = rgb
        for x in 0..<w {
            for y in 0..<h {
                for c in 0..<4 { prefix[(y + 1) * 4 + c] = prefix[y * 4 + c] + rows[(y * w + x) * 4 + c] }
            }
            for y in 0..<h where !skipping[y * w + x] {
                let lo = max(0, y - radius), hi = min(h - 1, y + radius) + 1
                let n = prefix[hi * 4 + 3] - prefix[lo * 4 + 3]
                guard n > 0 else { continue }
                for c in 0..<3 { out[(y * w + x) * 3 + c] = (prefix[hi * 4 + c] - prefix[lo * 4 + c]) / n }
            }
        }
        return out
    }
}
