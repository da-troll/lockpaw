import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A custom mascot's eye layers, ready to draw. See `EyeRig` for what each one is.
struct MascotRig {
    let plate: CGImage
    let pupils: CGImage
    let clip: CGImage
    let info: EyeRig.Info
}

/// The glue between `EyeRig`'s plain pixel buffers and the images on screen and on disk.
/// The three layers are kept as one small PNG, stacked top to bottom (plate, pupils, clip):
/// they are mostly transparent, so the file is a few tens of kilobytes.
enum EyeRigImages {
    /// Builds the layers for `image`. Blocking: tens of milliseconds for a 1024 px image.
    static func build(image: CGImage, eyes: MascotEyes) -> Result<EyeRig.Layers, EyeRejection> {
        guard let bitmap = EyeRig.Bitmap(image) else { return .failure(.cannotSeparate) }
        return EyeRig.build(image: bitmap, eyes: eyes)
    }

    static func atlasPNG(for layers: EyeRig.Layers) -> Data? {
        let w = layers.plate.width, h = layers.plate.height
        guard w > 0, h > 0, layers.pupils.width == w, layers.pupils.height == h,
              layers.clip.width == w, layers.clip.height == h
        else { return nil }
        let atlas = EyeRig.Bitmap(width: w, height: h * 3, rgba: layers.plate.rgba + layers.pupils.rgba + layers.clip.rgba)
        guard let image = atlas.cgImage else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func rig(fromAtlas data: Data, info: EyeRig.Info) -> MascotRig? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              atlas.height % 3 == 0, atlas.height > 0, atlas.width > 0
        else { return nil }
        let h = atlas.height / 3
        func layer(_ index: Int) -> CGImage? {
            atlas.cropping(to: CGRect(x: 0, y: index * h, width: atlas.width, height: h))
        }
        guard let plate = layer(0), let pupils = layer(1), let clip = layer(2) else { return nil }
        return MascotRig(plate: plate, pupils: pupils, clip: clip, info: info)
    }
}

extension EyeRig.Bitmap {
    /// The image's pixels as straight RGBA in sRGB, rows from the top.
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in 0..<(w * h) {
            let alpha = Int(data[i * 4 + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in 0..<3 { data[i * 4 + c] = UInt8(min(255, Int(data[i * 4 + c]) * 255 / alpha)) }
        }
        self.init(width: w, height: h, rgba: data)
    }

    var cgImage: CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var data = rgba
        for i in 0..<(width * height) {
            let alpha = Int(data[i * 4 + 3])
            guard alpha < 255 else { continue }
            for c in 0..<3 { data[i * 4 + c] = UInt8(Int(data[i * 4 + c]) * alpha / 255) }
        }
        return data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }
}
