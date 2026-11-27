import AVFoundation
import Combine
import Foundation
import Vision
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "Gaze")

/// Makes the custom mascot's eyes follow whoever walks past the locked Mac.
///
/// The camera runs only while `GazeCameraPolicy` says so: locked, the lock UI on screen
/// (each mounted eye overlay is a viewer; fade to black unmounts them), an image with eyes,
/// the setting on, camera access granted, and the Mac neither hot nor low on battery.
///
/// Privacy: frames are read in memory by Vision's built-in person detector, a few times a
/// second, and dropped. Nothing is saved, sent or logged; only a gaze point leaves the
/// frame queue. The camera light is on while it runs, and Settings says so.
@MainActor
final class GazeController: ObservableObject {
    static let shared = GazeController()

    /// UserDefaults key: the eyes follow passers-by. Off by default.
    static let enabledKey = "gazeEnabled"
    static let defaultEnabled = false

    /// Where the mascot looks, -1...1 per axis (+x right, +y down). Only the eye overlay
    /// observes this: it changes several times a second, and re-rendering the whole lock
    /// screen that often would re-target the mascot's breathing animation.
    @Published private(set) var gaze: CGPoint = .zero
    @Published private(set) var access: GazeCameraPolicy.Access

    private var viewers = 0
    private var locked = false
    private var cutOffForBattery = false
    private var tracker = GazeTracker()

    private var session: AVCaptureSession?
    private var processor: FrameProcessor?
    private let sessionQueue = DispatchQueue(label: "com.eriknielsen.lockpaw.gaze.session")
    private var powerTimer: Timer?
    private var thermalObserver: Any?

    private init() {
        access = Self.currentAccess()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    // MARK: - Inputs

    /// From `LockController.state`'s didSet. The password field (`.unlocking`) still counts
    /// as locked: someone is standing right there.
    func lockStateChanged(_ state: LockState) {
        locked = state == .locked || state == .unlocking
        evaluate()
    }

    /// An eye overlay appeared on a lock screen.
    func acquire() {
        viewers += 1
        CustomMascot.shared.refreshEyesIfNeeded()
        evaluate()
    }

    /// An eye overlay went away (unlock, fade to black, display unplugged).
    func release() {
        viewers = max(0, viewers - 1)
        evaluate()
    }

    /// Asks for the camera from Settings, never from the lock screen. True when granted.
    func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        access = Self.currentAccess()
        return granted
    }

    func refreshAccess() { access = Self.currentAccess() }

    // MARK: - Decision

    private func evaluate() {
        access = Self.currentAccess()
        let decision = GazeCameraPolicy.decide(
            enabled: UserDefaults.standard.bool(forKey: Self.enabledKey),
            hasEyes: CustomMascot.shared.eyes != nil,
            locked: locked,
            viewers: viewers,
            access: access,
            power: LidSleepController.currentPower(),
            thermal: LidSleepPolicy.Thermal(ProcessInfo.processInfo.thermalState),
            cutOffForBattery: cutOffForBattery
        )
        cutOffForBattery = decision.cutOffForBattery
        decision.run ? startCamera() : stopCamera()

        // Keep re-checking battery and heat for as long as anyone is watching, running or not,
        // so a Mac that cools down or gets plugged in picks the eyes back up.
        if locked && viewers > 0 {
            if powerTimer == nil {
                powerTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.lidPowerCheckInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.evaluate() }
                }
            }
        } else {
            powerTimer?.invalidate()
            powerTimer = nil
        }
    }

    // MARK: - Camera

    private func startCamera() {
        guard session == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            logger.info("Gaze: no camera available")
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let processor = FrameProcessor { [weak self] people in
            Task { @MainActor [weak self] in self?.received(people) }
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: processor.queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        self.session = session
        self.processor = processor
        tracker.reset()
        sessionQueue.async { session.startRunning() } // blocks; never on main
        logger.info("Gaze: camera on")
    }

    private func stopCamera() {
        guard let session else { return }
        self.session = nil
        let processor = self.processor
        self.processor = nil
        sessionQueue.async {
            session.stopRunning()
            _ = processor // keep the delegate alive until the session has stopped
        }
        tracker.reset()
        gaze = .zero
        logger.info("Gaze: camera off")
    }

    private func received(_ people: [CGRect]) {
        guard session != nil else { return } // a frame that landed after stop
        gaze = tracker.update(people: people, at: Date())
    }

    private static func currentAccess() -> GazeCameraPolicy.Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

/// Runs Vision's person detector on camera frames, at most `framesPerSecond` of them.
/// Lives on its own queue; hands only the boxes back.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Plenty for eyes that ease between targets, and cheap on the Neural Engine.
    static let framesPerSecond: Double = 8
    /// Below this Vision is guessing at a coat on a chair.
    static let minConfidence: Float = 0.5

    let queue = DispatchQueue(label: "com.eriknielsen.lockpaw.gaze.frames")
    private let onPeople: ([CGRect]) -> Void
    private let request: VNDetectHumanRectanglesRequest
    private var lastFrame: TimeInterval = 0 // only touched on `queue`

    init(onPeople: @escaping ([CGRect]) -> Void) {
        self.onPeople = onPeople
        request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true // people at desk distance rarely fit head to toe
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 1 / Self.framesPerSecond else { return }
        lastFrame = now

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        let people = (request.results ?? [])
            .filter { $0.confidence >= Self.minConfidence }
            .map(\.boundingBox)
        onPeople(people)
    }
}
