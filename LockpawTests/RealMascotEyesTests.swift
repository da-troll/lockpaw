import XCTest
@testable import Lockpaw

/// Runs the real eye finder and rig builder over real images and holds the outcome still.
///
/// The other eye tests draw their own eyes. This one is for the images someone has seen
/// working on their own lock screen, which a detector tweak could break without any of
/// those tests noticing.
///
/// The images are private, so they are not in the repository. Put any images in
/// `LockpawTests/LocalFixtures/Mascots/` (gitignored) and run the tests once: the outcome
/// for each is written to `expected.json` beside them. From then on a changed outcome
/// fails. To accept a change on purpose, delete `expected.json` (or one line of it) and
/// run again. With no images there, as in CI, the test is skipped.
final class RealMascotEyesTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("LocalFixtures/Mascots", isDirectory: true)
    private static let expectedURL = directory.appendingPathComponent("expected.json")

    /// What a prepared image ended as: this, or an `EyeRejection`'s raw value.
    private static let movingEyes = "eyes"

    func testEveryImageStillEndsTheSameWay() throws {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
            .filter { MascotFolder.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !names.isEmpty else {
            throw XCTSkip("No images in LockpawTests/LocalFixtures/Mascots")
        }

        let scratch = fm.temporaryDirectory.appendingPathComponent("RealMascotEyes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }

        // Each image takes a second or two in a Debug build, so they run side by side.
        let directory = Self.directory
        let lock = NSLock()
        var actual: [String: String] = [:]
        var problems: [String] = []
        DispatchQueue.concurrentPerform(iterations: names.count) { index in
            let name = names[index]
            let prepared = scratch.appendingPathComponent(name, isDirectory: true)
            var outcome: String?
            var problem: String?
            do {
                try MascotPreparer().prepare(source: directory.appendingPathComponent(name), into: prepared)
                let record = MascotPreparer.record(in: prepared)
                if record?.eyes != nil {
                    // "Eyes" only counts with layers that load, which is what the lock screen needs.
                    if MascotPreparer().load(from: prepared).rig == nil { problem = "\(name): eyes without layers" }
                    outcome = Self.movingEyes
                } else if let rejection = record?.rejection {
                    outcome = rejection.rawValue
                } else {
                    problem = "\(name): no verdict written"
                }
            } catch {
                problem = "\(name): \(error)"
            }
            lock.lock()
            if let outcome { actual[name] = outcome }
            if let problem { problems.append(problem) }
            lock.unlock()
        }
        XCTAssertEqual(problems.sorted(), [])

        var expected = (try? Data(contentsOf: Self.expectedURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let new = actual.filter { expected[$0.key] == nil }

        for (name, outcome) in actual.sorted(by: { $0.key < $1.key }) {
            if let was = expected[name] {
                XCTAssertEqual(outcome, was, "\(name) used to end as \(was)")
            }
        }

        if !new.isEmpty {
            expected.merge(new) { old, _ in old }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(expected).write(to: Self.expectedURL, options: .atomic)
        }
    }
}
