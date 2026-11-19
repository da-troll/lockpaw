import SwiftUI

/// The custom mascot's eyes, looking at whoever the camera sees.
///
/// No pupils are drawn: the image itself is drawn again on top, masked to the two eye
/// openings, and slid a little toward the gaze. Whatever the eyes look like (a photo, a
/// painting, a pet) they move as themselves, with no guess at an iris colour. The mask
/// stays put while the pixels under it slide, and its feathered edge hides the seam.
///
/// Mounting this is what asks for the camera (`GazeController.acquire`), so the camera runs
/// exactly while an eye overlay is on screen: never in Settings, never once faded to black.
@MainActor
struct MascotGazeOverlay: View {
    let image: NSImage
    let eyes: MascotEyes

    /// Observed here, in the leaf, and nowhere above: see `GazeController.gaze`.
    @ObservedObject private var controller = GazeController.shared

    var body: some View {
        GeometryReader { geo in
            let fit = EyeLayout.fittedRect(imageSize: image.size, in: geo.size)
            let offset = EyeLayout.pupilOffset(gaze: controller.gaze, eyes: eyes, fittedSize: fit.size)

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fit.width, height: fit.height)
                .offset(offset)
                // Frames arrive ~8 times a second; ease across each gap rather than step.
                .animation(.linear(duration: 0.15), value: controller.gaze)
                .mask { eyeMask(in: fit.size) }
                .position(x: fit.midX, y: fit.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { controller.acquire() }
        .onDisappear { controller.release() }
    }

    private func eyeMask(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            opening(EyeLayout.eyeRect(eyes.left, fittedSize: size))
            opening(EyeLayout.eyeRect(eyes.right, fittedSize: size))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func opening(_ rect: CGRect) -> some View {
        Ellipse()
            .fill(.black)
            .frame(width: rect.width, height: rect.height)
            .blur(radius: min(rect.width, rect.height) * 0.15)
            .offset(x: rect.minX, y: rect.minY)
    }
}
