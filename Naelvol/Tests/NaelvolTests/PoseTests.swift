import XCTest
import CoreGraphics
@testable import NaelvolPose

final class PoseTests: XCTestCase {
    /// A plausible address position: shoulders above hips above knees above
    /// ankles, hands together. Built once and bent per test.
    func person(score: Float = 0.9, move: [(BodyPart, CGPoint)] = [],
                scores: [(BodyPart, Float)] = []) -> Person {
        var layout: [BodyPart: CGPoint] = [
            .nose: CGPoint(x: 100, y: 20),
            .leftEye: CGPoint(x: 95, y: 15), .rightEye: CGPoint(x: 105, y: 15),
            .leftEar: CGPoint(x: 90, y: 18), .rightEar: CGPoint(x: 110, y: 18),
            .leftShoulder: CGPoint(x: 80, y: 60), .rightShoulder: CGPoint(x: 120, y: 60),
            .leftElbow: CGPoint(x: 75, y: 90), .rightElbow: CGPoint(x: 125, y: 90),
            .leftWrist: CGPoint(x: 100, y: 110), .rightWrist: CGPoint(x: 104, y: 110),
            .leftHip: CGPoint(x: 85, y: 120), .rightHip: CGPoint(x: 115, y: 120),
            .leftKnee: CGPoint(x: 85, y: 180), .rightKnee: CGPoint(x: 115, y: 180),
            .leftAnkle: CGPoint(x: 85, y: 240), .rightAnkle: CGPoint(x: 115, y: 240),
        ]
        for (part, point) in move { layout[part] = point }
        var perPart: [BodyPart: Float] = [:]
        for (part, s) in scores { perPart[part] = s }
        let points = BodyPart.allCases.map {
            KeyPoint(bodyPart: $0, coordinate: layout[$0] ?? .zero, score: perPart[$0] ?? score)
        }
        return Person(keyPoints: points, score: score)
    }

    func testGolferDerivesWristAndUnit() {
        let g = Golfer(person())
        // The synthetic wrist is the midpoint of the two hands.
        XCTAssertEqual(g.wrist.orgPt.x, 102, accuracy: 0.001)
        XCTAssertEqual(g.wrist.orgPt.y, 110, accuracy: 0.001)
        // `unit` is hip midpoint to knee midpoint: 120 → 180.
        XCTAssertEqual(g.unit, 60, accuracy: 0.001)
    }

    /// The wrist is only as trustworthy as the hand the model was least sure of.
    func testWristScoreIsTheWeakerHand() {
        let g = Golfer(person(scores: [(.leftWrist, 0.2), (.rightWrist, 0.95)]))
        XCTAssertEqual(g.wrist.score, 0.2, accuracy: 0.0001)
    }

    func testValidatorAcceptsAnAddressPosition() {
        XCTAssertTrue(PoseValidator().isValid(Golfer(person())))
    }

    func testValidatorRejectsShouldersBelowKnees() {
        // Upside down: the model found somebody lying on the tee box.
        let upside = person(move: [(.leftShoulder, CGPoint(x: 80, y: 200)),
                                   (.rightShoulder, CGPoint(x: 120, y: 200))])
        XCTAssertFalse(PoseValidator().isValid(Golfer(upside)))
    }

    /// Hands apart is somebody standing there, not somebody holding a club — and
    /// the threshold is in body units, so the same swing filmed from twice as far
    /// away is still valid.
    func testValidatorRejectsHandsApartAtAnyDistance() {
        let apart = person(move: [(.rightWrist, CGPoint(x: 160, y: 110))])
        XCTAssertFalse(PoseValidator().isValid(Golfer(apart)))

        var far: [(BodyPart, CGPoint)] = []
        for part in BodyPart.allCases {
            let p = person().keyPoints[part.position].coordinate
            far.append((part, CGPoint(x: p.x / 2, y: p.y / 2)))
        }
        XCTAssertTrue(PoseValidator().isValid(Golfer(person(move: far))))
    }

    func testValidatorRejectsALowScore() {
        XCTAssertFalse(PoseValidator().isValid(Golfer(person(score: 0.1))))
        // A missing hip is fatal; a single missing ankle is not — the other one
        // still says which way up the body is.
        XCTAssertFalse(PoseValidator().isValid(Golfer(person(scores: [(.leftHip, 0.05)]))))
        XCTAssertTrue(PoseValidator().isValid(Golfer(person(scores: [(.leftAnkle, 0.05)]))))
    }

    // MARK: - Crop

    func testInitialRegionPadsToASquare() {
        let crop = MoveNetCrop()
        let wide = crop.initialRegion(imageWidth: 1920, imageHeight: 1080)
        XCTAssertEqual(wide.height, 1, accuracy: 0.0001)
        XCTAssertEqual(wide.width * 1920, 1080, accuracy: 0.5)
        XCTAssertEqual(wide.left + wide.width / 2, 0.5, accuracy: 0.0001)

        let tall = crop.initialRegion(imageWidth: 1080, imageHeight: 1920)
        XCTAssertEqual(tall.width, 1, accuracy: 0.0001)
        XCTAssertEqual(tall.top + tall.height / 2, 0.5, accuracy: 0.0001)
    }

    func testNextRegionCentresOnTheHipsAndStaysSquare() {
        let crop = MoveNetCrop()
        // Shifted well inside the frame, because a crop that runs off an edge is
        // clamped and is no longer centred — the next test is about that.
        let shifted = BodyPart.allCases.map { part -> (BodyPart, CGPoint) in
            let p = person().keyPoints[part.position].coordinate
            return (part, CGPoint(x: p.x + 100, y: p.y + 80))
        }
        let points = person(move: shifted).keyPoints
        let region = crop.nextRegion(keyPoints: points, imageWidth: 400, imageHeight: 400)
        let centerX = (region.left + region.right) / 2 * 400
        let centerY = (region.top + region.bottom) / 2 * 400
        XCTAssertEqual(centerX, 200, accuracy: 1)   // hips at x 185 and 215
        XCTAssertEqual(centerY, 200, accuracy: 1)
        XCTAssertEqual(region.width * 400, region.height * 400, accuracy: 1)
    }

    /// A golfer near an edge gets a crop clipped by the frame, not one that walks
    /// off it. Clipped is right — there is no image out there — and it is why the
    /// square guarantee above holds only away from the edges.
    func testNextRegionIsClampedToTheFrame() {
        let crop = MoveNetCrop()
        let region = crop.nextRegion(keyPoints: person().keyPoints, imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(region.left, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(region.top, 0)
        XCTAssertLessThanOrEqual(region.right, 1)
        XCTAssertLessThanOrEqual(region.bottom, 1)
        // The hips it is centred on are still inside it.
        XCTAssertLessThan(region.left * 400, 100)
        XCTAssertGreaterThan(region.right * 400, 100)
    }

    /// No confident torso means no basis for a crop, so the model gets the whole
    /// padded frame back rather than a square around a guess.
    func testNextRegionFallsBackWhenTheTorsoIsNotVisible() {
        let crop = MoveNetCrop()
        let lost = person(scores: [(.leftHip, 0.05), (.rightHip, 0.05)]).keyPoints
        XCTAssertFalse(crop.torsoVisible(lost))
        let region = crop.nextRegion(keyPoints: lost, imageWidth: 1920, imageHeight: 1080)
        XCTAssertEqual(region, crop.initialRegion(imageWidth: 1920, imageHeight: 1080))
    }

    // MARK: - Collection

    func testCollectionDerivesVelocityAndAcceleration() {
        let collection = PoseCollection()
        for i in 0..<3 {
            // The wrist moves 10 px right per frame at 100 fps.
            let x = 100 + CGFloat(i * 10)
            var g = Golfer(person(move: [(.leftWrist, CGPoint(x: x, y: 110)),
                                         (.rightWrist, CGPoint(x: x + 4, y: 110))]))
            g.time = Double(i) * 0.01
            collection.append(g)
        }
        let last = collection.frames[2]
        XCTAssertEqual(last[.leftWrist].vx, 1000, accuracy: 1)   // 10 px / 0.01 s
        // Constant velocity: no acceleration, and the third frame is what makes
        // that answerable at all.
        XCTAssertEqual(last[.leftWrist].ax, 0, accuracy: 1)
        XCTAssertEqual(collection.frames[0][.leftWrist].vx, 0, accuracy: 0.0001)
    }

    func testCollectionSeeksToTheFrameAtOrBeforeATime() {
        let collection = PoseCollection()
        for i in 0..<5 {
            var g = Golfer(person())
            g.time = Double(i) * 0.1
            collection.append(g)
        }
        XCTAssertEqual(collection.pose(at: 0.2)?.time ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(collection.pose(at: 0.25)?.time ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertNil(collection.pose(at: -1))
        XCTAssertEqual(collection.duration, 0.4, accuracy: 0.0001)
    }
}

final class XPoseTriggerTests: XCTestCase {
    /// Arms crossed in front of the chest: wrists between the shoulders and above
    /// the elbows, elbows out wide.
    func crossed() -> Golfer {
        var g = Golfer()
        func set(_ part: GolferPart, _ x: CGFloat, _ y: CGFloat) {
            var p = GolferBodyPoint()
            p.part = part
            p.pt = CGPoint(x: x, y: y)
            p.orgPt = p.pt
            p.score = 0.9
            g[part] = p
        }
        set(.leftShoulder, 60, 100); set(.rightShoulder, 140, 100)
        set(.leftElbow, 40, 150); set(.rightElbow, 160, 150)
        set(.leftWrist, 98, 130); set(.rightWrist, 102, 130)
        return g
    }

    func testFiresOnlyAfterTheHold() {
        var trigger = XPoseTrigger()
        let t0 = Date()
        XCTAssertEqual(trigger.update(crossed(), now: t0), .arming)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(0.2)), .arming)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(0.6)), .fire)
    }

    /// Letting the arms drop mid-hold starts the clock over, or a glance at the
    /// phone on the way to address becomes a recording.
    func testBreakingThePoseRestartsTheHold() {
        var trigger = XPoseTrigger()
        let t0 = Date()
        _ = trigger.update(crossed(), now: t0)
        XCTAssertEqual(trigger.update(Golfer(), now: t0.addingTimeInterval(0.2)), .idle)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(0.4)), .arming)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(0.7)), .arming)
    }

    /// After a fire the trigger is deaf, or the same held pose starts and stops
    /// the recording on every frame.
    func testRefractoryPeriod() {
        var trigger = XPoseTrigger()
        let t0 = Date()
        _ = trigger.update(crossed(), now: t0)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(0.6)), .fire)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(1.5)), .idle)
        XCTAssertEqual(trigger.update(crossed(), now: t0.addingTimeInterval(4.0)), .arming)
    }

    func testUnseenArmsNeverFire() {
        var trigger = XPoseTrigger()
        var faint = crossed()
        faint[.leftWrist].score = 0.1
        XCTAssertEqual(trigger.update(faint), .idle)
    }
}
