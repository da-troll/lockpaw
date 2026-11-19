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
    /// Added to the vertical gaze, so the eyes look a little lower than the geometry says.
    /// The camera sits above the screen and a seated person's head is in the upper part of
    /// its frame, which reads as "up"; but eyes on a screen that look straight out already
    /// seem to look at whoever is in front of them, so that "up" lands above the person.
    /// Found on a laptop: the eyes sat consistently a little too high.
    static let downwardBias: CGFloat = 0.3

    /// A person has to be seen this many frames in a row before the eyes follow them, so a
    /// one-frame false detection can't flick the gaze toward an empty corner.
    static let framesToConfirm = 3
    /// While following someone, another person only takes over when their box is this many
    /// times bigger (by area). Two people of similar size would otherwise swap frame to frame.
    static let switchAreaRatio: CGFloat = 1.5
    /// The gaze never moves faster than this, in gaze units per second, following or homing.
    static let maxSpeed: CGFloat = 2.5

    private(set) var gaze: CGPoint = .zero
    private var target: CGPoint = .zero
    /// True from the frame someone is confirmed until the hold after losing them runs out.
    private var following = false
    /// Frames in a row with someone in view.
    private var seenStreak = 0
    private var lastSeen: Date?
    private var lastUpdate: Date?

    /// `people` are Vision's boxes as it reports them: normalized, bottom-left origin, in the
    /// camera's unmirrored frame. Returns the new gaze.
    @discardableResult
    mutating func update(people: [CGRect], at now: Date) -> CGPoint {
        let dt = lastUpdate.map { min(max(now.timeIntervalSince($0), 0), 1) } ?? 0
        lastUpdate = now

        let visible = people.filter { $0.width > 0 && $0.height > 0 }
        seenStreak = visible.isEmpty ? 0 : seenStreak + 1

        let timeConstant: TimeInterval
        if following, let person = Self.pick(from: visible, following: target) {
            // Back after a dropped frame counts at once: they were already confirmed.
            target = Self.head(of: person)
            lastSeen = now
            timeConstant = Self.followTimeConstant
        } else if following, let lastSeen, now.timeIntervalSince(lastSeen) <= Self.holdAfterLoss {
            timeConstant = Self.followTimeConstant
        } else if seenStreak >= Self.framesToConfirm, let person = Self.pick(from: visible, following: nil) {
            following = true
            target = Self.head(of: person)
            lastSeen = now
            timeConstant = Self.followTimeConstant
        } else {
            following = false
            target = .zero
            timeConstant = Self.homeTimeConstant
        }

        let alpha = CGFloat(1 - exp(-dt / timeConstant))
        var step = CGVector(dx: (target.x - gaze.x) * alpha, dy: (target.y - gaze.y) * alpha)
        let length = (step.dx * step.dx + step.dy * step.dy).squareRoot()
        let limit = Self.maxSpeed * CGFloat(dt)
        if length > limit {
            let scale = length > 0 ? limit / length : 0
            step = CGVector(dx: step.dx * scale, dy: step.dy * scale)
        }
        gaze = CGPoint(x: gaze.x + step.dx, y: gaze.y + step.dy)
        return gaze
    }

    /// Back to straight ahead, for a new lock session.
    mutating func reset() { self = GazeTracker() }

    /// Who to look at. With nobody followed yet (`current` nil): the largest, so nearest,
    /// person. While following: whoever's head is closest to where the eyes are already
    /// aimed, unless someone else's box is `switchAreaRatio` times bigger.
    static func pick(from people: [CGRect], following current: CGPoint?) -> CGRect? {
        let visible = people.filter { $0.width > 0 && $0.height > 0 }
        guard let largest = visible.max(by: { area($0) < area($1) }) else { return nil }
        guard let current, let same = visible.min(by: {
            distanceSquared(head(of: $0), current) < distanceSquared(head(of: $1), current)
        }) else { return largest }
        return area(largest) > area(same) * switchAreaRatio ? largest : same
    }

    /// Where to look for these detections with nobody followed yet: the head of the largest
    /// (so nearest) person.
    static func target(for people: [CGRect]) -> CGPoint? {
        pick(from: people, following: nil).map(head(of:))
    }

    /// The gaze that looks at this person's head.
    ///
    /// The camera faces the room, so its frame is the room seen from the screen: someone on
    /// the camera's left is on the *viewer's* right. The mascot faces the room too, so it
    /// looks toward image-left as screen-right — hence the mirror on x.
    static func head(of person: CGRect) -> CGPoint {
        let headX = person.midX
        let headY = person.maxY - person.height * headFromTop // Vision: y up
        return CGPoint(
            x: (1 - 2 * headX).clamped(to: -1...1),
            y: (1 - 2 * headY + downwardBias).clamped(to: -1...1)
        )
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
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

    /// Whether the Settings switch reads as on: the user's choice, with the camera granted.
    ///
    /// Takes nothing about the image on purpose. It once followed whether the current
    /// image had eyes, and switching from Image to Folder made the switch read off although
    /// nobody had turned it off. `decide` is where the eyes matter.
    static func settingShowsOn(enabled: Bool, access: Access) -> Bool {
        enabled && access == .authorized
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
