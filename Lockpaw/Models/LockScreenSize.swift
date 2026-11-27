import CoreGraphics
import Foundation

/// How big the lock screen's mascot and its text are drawn: Small, Medium or Large, chosen
/// separately for each (Settings → Lock Screen). Small is the look the lock screen always
/// had, so nothing changes for anyone who never touches the setting; the other two only
/// go up from there.
///
/// Pure: the scales and where the resized mascot sits are tested without a view.
enum LockScreenSize: String, CaseIterable, Identifiable {
    case small, medium, large

    static let mascotStorageKey = "lockMascotSize"
    static let textStorageKey = "lockTextSize"
    static let defaultValue = LockScreenSize.small

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Multiplies the mascot's side.
    var mascotScale: CGFloat {
        switch self {
        case .small: return 1.0
        case .medium: return 1.35
        case .large: return 1.7
        }
    }

    /// Multiplies the point size of the message, the timer and the waiting-agent rows.
    /// The unlock prompt and the password pill at the bottom keep their size: the pill is
    /// the password field's exact footprint, so opening it moves nothing.
    var textScale: CGFloat {
        switch self {
        case .small: return 1.0
        case .medium: return 1.4
        case .large: return 1.8
        }
    }

    static func resolved(from rawValue: String?) -> LockScreenSize {
        rawValue.flatMap(LockScreenSize.init(rawValue:)) ?? defaultValue
    }

    /// Where the mascot goes on a screen of `screen` points.
    struct MascotLayout: Equatable {
        /// The mascot's frame is `side` × `side`.
        var side: CGFloat
        /// Empty space above the mascot.
        var topInset: CGFloat
        /// Spacing unit for the stack under the mascot. Tied to the Small mascot so a
        /// bigger mascot doesn't also push the message and timer further away.
        var unit: CGFloat
    }

    /// The mascot grows around the point where the Small mascot's centre sits, so a bigger
    /// one takes half its extra height from above rather than pushing the text and the
    /// unlock button down by all of it. Its bottom edge never passes `maxBottomFraction` of
    /// the screen (past that it grows upward only), which is what keeps the message, the
    /// timer and the unlock area on a laptop display under a Large mascot. The inset never
    /// drops below a tenth of the screen.
    func mascotLayout(in screen: CGSize) -> MascotLayout {
        let base = min(screen.width * Self.baseWidthFraction, screen.height * Self.baseHeightFraction)
        let side = base * mascotScale
        let centre = screen.height * Self.baseTopFraction + base / 2
        let inset = min(centre - side / 2, screen.height * Self.maxBottomFraction - side)
        return MascotLayout(
            side: side,
            topInset: max(inset, screen.height * Self.minTopFraction),
            unit: base * 0.12
        )
    }

    static let baseWidthFraction: CGFloat = 0.2
    static let baseHeightFraction: CGFloat = 0.3
    static let baseTopFraction: CGFloat = 0.32
    static let minTopFraction: CGFloat = 0.1
    static let maxBottomFraction: CGFloat = 0.66
}
