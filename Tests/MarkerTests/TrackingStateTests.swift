import XCTest
@testable import GolfSessionFormat

/// "Location is on" and "location is usable" are different claims, and the app was
/// making only the first. A first fix arrives fast and can be hundreds of metres
/// out; a yardage read off it looks like the app working and is wrong by a hole.
final class TrackingStateTests: XCTestCase {

    private func t(_ seconds: Double) -> Millis { Millis(seconds * 1000) }

    func testOffUntilAModeIsChosen() {
        var m = TrackingMonitor()
        XCTAssertEqual(m.state.phase, .off)
        XCTAssertEqual(m.state.mode, .off)
        // A fix arriving while off must not quietly start things.
        m.accept(accuracy: 5, at: t(1))
        XCTAssertEqual(m.state.fixCount, 0)
    }

    func testTrackingStartsBySearching() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        XCTAssertEqual(m.state.phase, .searching)
        XCTAssertFalse(m.state.isUsable)
    }

    /// One good fix is not a lock. The radio routinely follows a good fix with a bad
    /// one while it is still warming up, and locking on the first would make the
    /// indicator claim more than it knows.
    func testOneGoodFixIsStabilisingNotLocked() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        m.accept(accuracy: 6, at: t(1))
        XCTAssertEqual(m.state.phase, .stabilizing)
        XCTAssertTrue(m.state.isUsable)
    }

    func testThreeConsecutiveGoodFixesLock() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        for i in 1...TrackingState.lockRun { m.accept(accuracy: 8, at: t(Double(i))) }
        XCTAssertEqual(m.state.phase, .locked)
        XCTAssertEqual(m.state.accuracy, 8)
        XCTAssertEqual(m.state.fixCount, 3)
    }

    /// A bad fix breaks the run. Two good, one poor, two good must not be a lock —
    /// that is five fixes without three consecutive good ones.
    func testABadFixBreaksTheRun() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        m.accept(accuracy: 8, at: t(1))
        m.accept(accuracy: 8, at: t(2))
        m.accept(accuracy: 60, at: t(3))
        m.accept(accuracy: 8, at: t(4))
        m.accept(accuracy: 8, at: t(5))
        XCTAssertEqual(m.state.phase, .stabilizing)
    }

    /// CoreLocation reports negative accuracy for an invalid fix. It must not count
    /// as a fix at all, let alone a good one.
    func testAnInvalidFixIsIgnoredEntirely() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        m.accept(accuracy: -1, at: t(1))
        XCTAssertEqual(m.state.fixCount, 0)
        XCTAssertEqual(m.state.phase, .searching)
    }

    /// Under trees or in a pocket the last fix can be minutes old. A lock that stops
    /// being fed has to decay, or a stale position keeps being shown as current.
    func testALockGoesStale() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        for i in 1...3 { m.accept(accuracy: 5, at: t(Double(i))) }
        XCTAssertEqual(m.state.phase, .locked)

        m.tick(now: t(3 + TrackingState.staleAfter - 1))
        XCTAssertEqual(m.state.phase, .locked, "not stale yet")

        m.tick(now: t(3 + TrackingState.staleAfter + 1))
        XCTAssertEqual(m.state.phase, .searching)
        XCTAssertNil(m.state.accuracy)
    }

    func testDeniedPermissionIsItsOwnPhaseNotSearching() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        m.setBlocked(true)
        XCTAssertEqual(m.state.phase, .blocked)
        m.accept(accuracy: 5, at: t(1))
        XCTAssertEqual(m.state.fixCount, 0, "a blocked monitor must not take fixes")
        m.setBlocked(false)
        XCTAssertEqual(m.state.phase, .searching)
    }

    func testTurningOffClearsEverything() {
        var m = TrackingMonitor()
        m.setMode(.fast)
        for i in 1...3 { m.accept(accuracy: 5, at: t(Double(i))) }
        m.setMode(.off)
        XCTAssertEqual(m.state, TrackingState())
    }

    /// The mode is what the phone is doing; the phase is how far along it is. They
    /// are independent, and the indicator shows both.
    func testModeAndPhaseAreIndependent() {
        var m = TrackingMonitor()
        m.setMode(.slow)
        for i in 1...3 { m.accept(accuracy: 9, at: t(Double(i))) }
        XCTAssertEqual(m.state.mode, .slow)
        XCTAssertEqual(m.state.phase, .locked)
        XCTAssertEqual(m.state.summary, "Slow · Locked ±9m")

        m.setMode(.fast)
        XCTAssertEqual(m.state.phase, .locked, "changing rate must not lose the lock")
        XCTAssertEqual(m.state.summary, "Fast · Locked ±9m")
    }
}
