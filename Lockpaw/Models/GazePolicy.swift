import CoreGraphics
import Foundation

/// Turns what the camera sees into where the mascot looks. Pure, so the direction, the
/// smoothing and the give-up-and-look-ahead timing are tested without a camera.
///
/// Gaze is -1...1 on each axis in screen terms: +x looks right, +y looks down.
struct GazeTracker {
    /// After the last sighting, keep looking where they were for this long: Vision drops a
    /// person for a frame or two as they turn, and the eyes snapping home would read as a blink.
    static let holdAfterLoss: TimeInterval = 1.5
    /// Follow a person this quickly (time to cover ~63% of the way)…
    static let followTimeConstant: TimeInterval = 0.25
    /// …and drift back to looking straight ahead this slowly once they've gone.
    static let homeTimeConstant: TimeInterval = 0.8
    /// The head sits this far down from the top of an upper-body box.
    static let headFromTop: CGFloat = 0.15

    private(set) var gaze: CGPoint = .zero
    private var target: CGPoint = .zero
    private var lastSeen: Date?
    private var lastUpdate: Date?

    /// `people` are Vision's boxes as it reports them: normalized, bottom-left origin, in the
    /// camera's unmirrored frame. Returns the new gaze.
    @discardableResult
    mutating func update(people: [CGRect], at now: Date) -> CGPoint {
        let dt = lastUpdate.map { min(max(now.timeIntervalSince($0), 0), 1) } ?? 0
        lastUpdate = now

        let timeConstant: TimeInterval
        if let seen = Self.target(for: people) {
            target = seen
            lastSeen = now
            timeConstant = Self.followTimeConstant
        } else if let lastSeen, now.timeIntervalSince(lastSeen) <= Self.holdAfterLoss {
            timeConstant = Self.followTimeConstant
        } else {
            target = .zero
            timeConstant = Self.homeTimeConstant
        }

        let alpha = CGFloat(1 - exp(-dt / timeConstant))
        gaze = CGPoint(x: gaze.x + (target.x - gaze.x) * alpha, y: gaze.y + (target.y - gaze.y) * alpha)
        return gaze
    }

    /// Back to straight ahead, for a new lock session.
    mutating func reset() { self = GazeTracker() }

    /// Where to look for these detections: the head of the largest (so nearest) person.
    ///
    /// The camera faces the room, so its frame is the room seen from the screen: someone on
    /// the camera's left is on the *viewer's* right. The mascot faces the room too, so it
    /// looks toward image-left as screen-right — hence the mirror on x.
    static func target(for people: [CGRect]) -> CGPoint? {
        guard let nearest = people
            .filter({ $0.width > 0 && $0.height > 0 })
            .max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return nil }
        let headX = nearest.midX
        let headY = nearest.maxY - nearest.height * headFromTop // Vision: y up
        return CGPoint(
            x: (1 - 2 * headX).clamped(to: -1...1),
            y: (1 - 2 * headY).clamped(to: -1...1)
        )
    }
}

/// When the camera may run for the gaze. Pure, so the safety cutouts are unit-tested.
///
/// The camera only runs while it has an audience and a reason: locked, the lock UI on
/// screen (not faded to black), an image that has eyes, and the user's say-so. Never
/// against the machine's interest: hot or low on battery, the eyes rest.
enum GazeCameraPolicy {
    /// At or below this on battery the camera stops. Higher than lid-closed mode's floor:
    /// this is decoration, not keeping an agent alive.
    static let batteryFloor = 30
    /// Hysteresis, so a reading wobbling around the floor can't flap the camera light.
    static let batteryResume = 35

    enum Access: Equatable {
        case authorized
        /// Never prompt from the lock screen: the dialog would open behind the cover with
        /// input blocked. Settings asks when the toggle goes on.
        case notDetermined
        case denied
    }

    struct Decision: Equatable {
        var run: Bool
        var cutOffForBattery: Bool
    }

    static func decide(
        enabled: Bool,
        hasEyes: Bool,
        locked: Bool,
        viewers: Int,
        access: Access,
        power: LidSleepPolicy.Power,
        thermal: LidSleepPolicy.Thermal,
        cutOffForBattery: Bool
    ) -> Decision {
        let cutOff: Bool
        if !power.onBattery {
            cutOff = false
        } else if let percent = power.batteryPercent {
            cutOff = cutOffForBattery ? percent < batteryResume : percent <= batteryFloor
        } else {
            cutOff = cutOffForBattery
        }
        let hot = thermal == .serious || thermal == .critical
        let run = enabled && hasEyes && locked && viewers > 0 && access == .authorized && !cutOff && !hot
        return Decision(run: run, cutOffForBattery: cutOff)
    }
}
