import SwiftUI

/// The custom mascot's eyes, looking at whoever the camera sees.
///
/// Drawn from the three layers `EyeRig` cut at install, the way a hand-made 2D rig works:
/// the plate paints the eye in where each pupil was, then the pupils are drawn on top, slid
/// toward the gaze and clipped to the eyes. Only the pupils move. Lids, rims and sockets are
/// the image underneath, untouched, so there is no cut edge to see.
///
/// Laid over the fitted mascot image, so its own size is the image's size on screen.
///
/// Mounting this is what asks for the camera (`GazeController.acquire`), so the camera runs
/// exactly while an eye overlay is on screen: never in Settings, never once faded to black.
@MainActor
struct MascotGazeOverlay: View {
    let rig: MascotRig

    /// Observed here, in the leaf, and nowhere above: see `GazeController.gaze`.
    @ObservedObject private var controller = GazeController.shared

    var body: some View {
        GeometryReader { geo in
            let rect = rig.info.rect
            let size = CGSize(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
            let offset = EyeRig.offset(gaze: controller.gaze, travel: rig.info.travel, fittedSize: geo.size)

            ZStack {
                layer(rig.plate, size: size)
                layer(rig.pupils, size: size)
                    .offset(offset)
                    // Frames arrive ~8 times a second; ease across each gap rather than step.
                    .animation(.linear(duration: 0.15), value: controller.gaze)
                    // After the offset, so the clip stays put while the pupils slide under it.
                    .mask { layer(rig.clip, size: size) }
            }
            .frame(width: size.width, height: size.height)
            .position(x: rect.midX * geo.size.width, y: rect.midY * geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { controller.acquire() }
        .onDisappear { controller.release() }
    }

    private func layer(_ image: CGImage, size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
    }
}
