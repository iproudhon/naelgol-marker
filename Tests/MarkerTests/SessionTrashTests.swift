import XCTest
import GolfSessionFormat

/// Deleting a round, and getting it back.
///
/// The assertions are about the two ways a recoverable delete fails: losing the
/// round it was meant to keep, and overwriting a live one on the way back.
final class SessionTrashTests: XCTestCase {

    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marker-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let t: Millis = 1_756_600_000_000

    @discardableResult
    private func makeRound(_ name: String, course: String = "Test Links",
                           start: Millis? = nil) throws -> SessionFolder {
        let folder = SessionFolder(url: root.appendingPathComponent(name))
        try folder.create()
        try folder.writeMeta(SessionMeta(sessionID: name, course: course,
                                         players: [Player(name: "steve")],
                                         start: start ?? t, end: (start ?? t) + 1_000,
                                         device: "test", audioFormat: "none"))
        let w = try folder.writer(.log)
        try w.append(LogEntry(id: "l1", t: start ?? t, text: "hello", source: .typed))
        try w.close()
        return folder
    }

    // MARK: - A deleted round leaves the list and is still there

    func testDeletingMovesTheRoundOutOfTheListWithoutDestroyingIt() throws {
        let folder = try makeRound("session-a")
        XCTAssertEqual(SessionIndex.summaries(in: root).count, 1)

        let trashed = try SessionTrash.discard(folder, in: root, at: t)

        // Gone from the rounds list **by construction**: the scan skips hidden
        // files, so nothing has to remember to filter the trash out.
        XCTAssertTrue(SessionIndex.summaries(in: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))

        let bin = SessionTrash.contents(in: root)
        XCTAssertEqual(bin.count, 1)
        XCTAssertEqual(bin.first?.deletedAt, t)
        XCTAssertEqual(bin.first?.summary.courseName, "Test Links")
        // Every row is still there.
        XCTAssertEqual(SessionFolder(url: trashed).readAll(.log, as: LogEntry.self).count, 1)
    }

    func testRestoringPutsBackExactlyWhatWasDeleted() throws {
        let folder = try makeRound("session-a")
        let before = folder.readAll(.log, as: LogEntry.self)
        let trashed = try SessionTrash.discard(folder, in: root)
        let back = try SessionTrash.restore(trashed, to: root)

        XCTAssertEqual(back.lastPathComponent, "session-a")
        XCTAssertEqual(SessionIndex.summaries(in: root).count, 1)
        XCTAssertTrue(SessionTrash.contents(in: root).isEmpty)
        XCTAssertEqual(SessionFolder(url: back).readAll(.log, as: LogEntry.self), before)
        // The stamp is a fact about being in the trash and must not come back out
        // with the round.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: back.appendingPathComponent(".deleted").path))
    }

    // MARK: - Neither move may overwrite

    /// A folder of that name can appear while the round is in the trash — an import,
    /// or a round started in the same minute. Replacing it would destroy a live
    /// round through the control that exists to undo a destruction.
    func testRestoringNeverOverwritesARoundThatAppearedMeanwhile() throws {
        let original = try makeRound("session-a", course: "Original")
        let trashed = try SessionTrash.discard(original, in: root)
        try makeRound("session-a", course: "Newcomer")      // same name, different round

        let back = try SessionTrash.restore(trashed, to: root)
        XCTAssertEqual(back.lastPathComponent, "session-a-2")
        let names = SessionIndex.summaries(in: root).compactMap(\.courseName).sorted()
        XCTAssertEqual(names, ["Newcomer", "Original"], "both rounds survive")
    }

    func testDeletingTwoRoundsOfTheSameNameKeepsBoth() throws {
        try SessionTrash.discard(try makeRound("session-a", course: "First"), in: root)
        try SessionTrash.discard(try makeRound("session-a", course: "Second"), in: root)
        XCTAssertEqual(SessionTrash.contents(in: root).count, 2)
        XCTAssertEqual(SessionTrash.contents(in: root).compactMap(\.summary.courseName).sorted(),
                       ["First", "Second"])
    }

    // MARK: - Purging

    func testPurgeIsPermanentAndEmptyTakesEverything() throws {
        try SessionTrash.discard(try makeRound("session-a"), in: root)
        try SessionTrash.discard(try makeRound("session-b", start: t + 60_000), in: root)
        XCTAssertEqual(try SessionTrash.empty(in: root), 2)
        XCTAssertTrue(SessionTrash.contents(in: root).isEmpty)
        XCTAssertTrue(SessionIndex.summaries(in: root).isEmpty)
    }

    func testRetentionPurgesWhatIsOldAndLeavesWhatIsNot() throws {
        let old = try makeRound("session-old")
        let recent = try makeRound("session-recent", start: t + 60_000)
        try SessionTrash.discard(old, in: root, at: t)
        try SessionTrash.discard(recent, in: root, at: t)

        let justInside = t + Millis(SessionTrash.retention * 1000)
        XCTAssertTrue(SessionTrash.purgeExpired(in: root, now: justInside).isEmpty,
                      "exactly at the window is still inside it")

        // Age only one of them, by rewriting its stamp.
        let bin = SessionTrash.contents(in: root)
        let target = try XCTUnwrap(bin.first { $0.summary.meta.sessionID == "session-old" })
        try Data("\(t)".utf8).write(to: target.url.appendingPathComponent(".deleted"))
        let past = t + Millis(SessionTrash.retention * 1000) + 1_000

        // The recent one is stamped in the future relative to nothing — restamp it
        // so only the old one expires.
        let other = try XCTUnwrap(bin.first { $0.summary.meta.sessionID == "session-recent" })
        try Data("\(past)".utf8).write(to: other.url.appendingPathComponent(".deleted"))

        XCTAssertEqual(SessionTrash.purgeExpired(in: root, now: past), ["session-old"])
        XCTAssertEqual(SessionTrash.contents(in: root).count, 1)
    }

    /// A folder with no stamp — moved in by hand, or one whose stamp was lost.
    /// **Never treated as "deleted now"**, which would restart the window on every
    /// scan and keep it forever while claiming a date; and never purged, because
    /// nothing knows how old it is.
    func testAnUnstampedRoundIsNeitherDatedNorPurged() throws {
        let folder = try makeRound("session-a")
        let trashed = try SessionTrash.discard(folder, in: root)
        try FileManager.default.removeItem(at: trashed.appendingPathComponent(".deleted"))

        let d = try XCTUnwrap(SessionTrash.contents(in: root).first)
        XCTAssertNil(d.deletedAt)
        XCTAssertNil(d.expires)
        XCTAssertTrue(SessionTrash.purgeExpired(in: root, now: t + 10_000_000_000).isEmpty)
        XCTAssertEqual(SessionTrash.contents(in: root).count, 1)
    }

    // MARK: - The shared uniquifier

    func testFreeNameSuffixesRatherThanCollides() throws {
        XCTAssertEqual(SessionFolder.freeName("session-a", in: root), "session-a")
        try makeRound("session-a")
        XCTAssertEqual(SessionFolder.freeName("session-a", in: root), "session-a-2")
        try makeRound("session-a-2")
        XCTAssertEqual(SessionFolder.freeName("session-a", in: root), "session-a-3")
    }
}
