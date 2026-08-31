import XCTest
@testable import GolfCourse

/// A card is par, handicap and yardage with **no coordinates**. Everything here
/// guards one of the two ways that goes silently wrong: a unit read as the wrong
/// one (10% off on every hole, and it looks fine), and a hole number that is not
/// unique because the course names its nines.
final class CourseCardTests: XCTestCase {

    // 안성CC, Out course, verbatim — a real card printed in yards with no unit marker.
    // research-scorecard-import.md §3.
    private func ansungOut() -> CourseCard.Nine {
        let pars = [4, 4, 3, 4, 5, 5, 3, 4, 4]
        let hcps = [4, 1, 6, 2, 7, 5, 9, 8, 3]
        let back = [383.0, 404, 200, 423, 525, 548, 167, 395, 392]
        let reg = [358.0, 373, 174, 383, 500, 527, 149, 365, 370]
        let holes = (0..<9).map { i in
            CourseCard.CardHole(ref: "\(i + 1)", par: pars[i], handicap: hcps[i],
                                tees: [.init(name: "Back", distance: back[i]),
                                       .init(name: "Regular", distance: reg[i])])
        }
        return CourseCard.Nine(name: "OUT", holes: holes, printedPar: 36,
                               printedTees: [.init(name: "Back", distance: 3437),
                                             .init(name: "Regular", distance: 3199)])
    }

    // MARK: - Units

    func testYardsAreNormalisedToMetresOnce() throws {
        let card = CourseCard(courseName: "안성CC", unit: "yards", nines: [ansungOut()])
        let course = card.course(id: "ansung-cc", unit: .yards)
        let h1 = try XCTUnwrap(course.hole(nine: "OUT", ref: "1"))
        // 383 yd = 350.2 m. If this reads 383 the unit was ignored.
        XCTAssertEqual(try XCTUnwrap(h1.cardLength()), 350.2, accuracy: 0.2)
        XCTAssertEqual(course.cardUnit, .yards, "the source unit must survive for a later fix")
    }

    /// The trap this whole mechanism exists for. Same numbers, declared metres:
    /// every hole is now 9.4% longer and nothing looks wrong.
    func testTheSameCardReadAsMetresIsTenPercentDifferent() throws {
        let card = CourseCard(courseName: "안성CC", unit: "yards", nines: [ansungOut()])
        let asYards = try XCTUnwrap(card.course(id: "x", unit: .yards).hole(nine: "OUT", ref: "1")?.cardLength())
        let asMetres = try XCTUnwrap(card.course(id: "x", unit: .metres).hole(nine: "OUT", ref: "1")?.cardLength())
        XCTAssertEqual(asMetres / asYards, 1 / 0.9144, accuracy: 0.001)
    }

    /// A silent card gets the regional assumption, not a refusal and not a guess.
    /// 6,300 over par 72 is the modal American public course from the tips; it is
    /// also squarely inside the metric range. Refusing here would stop the most
    /// ordinary import there is.
    func testASilentCardTakesTheRegionalAssumptionAndSaysSo() {
        var holes: [CourseCard.CardHole] = []
        for i in 1...18 {
            holes.append(.init(ref: "\(i)", par: 4, handicap: i,
                               tees: [.init(name: "Back", distance: 350)]))
        }
        let card = CourseCard(courseName: "?", unit: "unknown",
                              nines: [.init(name: nil, holes: holes)])
        let (unit, source) = card.resolveUnit()
        XCTAssertEqual(unit, .yards, "American cards are yards; that is the default")
        XCTAssertEqual(source, .assumed)
        XCTAssertTrue(source.needsChecking, "an assumed unit must be flagged for checking")
        XCTAssertNil(card.unitWarning(), "6,300 over par 72 is plausible — no warning")
    }

    /// The same silence, in a metric region. The default is a parameter precisely
    /// so importing a Korean card is a flag, not a fork in the code.
    func testTheRegionalAssumptionIsAParameter() {
        let card = CourseCard(courseName: "천룡CC", unit: "unknown", nines: [ansungOut()])
        let (unit, source) = card.resolveUnit(assuming: .metres)
        XCTAssertEqual(unit, .metres)
        XCTAssertEqual(source, .assumed)
    }

    func testAPrintedUnitBeatsTheAssumptionAndAnOverrideBeatsBoth() {
        let metric = CourseCard(courseName: "도고", unit: "metres", nines: [ansungOut()])
        let (u1, s1) = metric.resolveUnit()
        XCTAssertEqual(u1, .metres, "the card printed (M) — do not override it with the region")
        XCTAssertEqual(s1, .printed)

        let (u2, s2) = metric.resolveUnit(preferring: .yards)
        XCTAssertEqual(u2, .yards)
        XCTAssertEqual(s2, .explicit)
    }

    /// An impossible total is a misread column, and that *is* detectable — unlike
    /// the unit, which is not.
    func testAnImpossibleTotalIsFlagged() {
        var holes: [CourseCard.CardHole] = []
        for i in 1...18 {
            // A totals row read as a hole: 3,400 per "hole".
            holes.append(.init(ref: "\(i)", par: 4, handicap: i,
                               tees: [.init(name: "Back", distance: 3400)]))
        }
        let card = CourseCard(courseName: "?", unit: "unknown",
                              nines: [.init(name: nil, holes: holes)])
        XCTAssertNotNil(card.unitWarning())
    }

    // MARK: - Reconciliation against the card's own totals

    func testACleanCardHasNoIssues() {
        let card = CourseCard(courseName: "안성CC", unit: "yards", nines: [ansungOut()])
        XCTAssertEqual(card.issues(), [], "a verbatim real card must reconcile")
    }

    /// The failure that matters: one transposed digit. The hole still looks like a
    /// golf hole; only the printed total disagrees.
    func testATransposedDigitIsCaughtByTheTotalsRow() {
        var nine = ansungOut()
        nine.holes[3].tees[0].distance = 432   // 423 transposed
        let card = CourseCard(courseName: "안성CC", unit: "yards", nines: [nine])
        let issues = card.issues()
        XCTAssertTrue(issues.contains { $0.kind == .teeSumMismatch },
                      "9 off the printed total must be flagged, got \(issues)")
        XCTAssertTrue(issues.contains { $0.blocking })
    }

    func testAMisreadParColumnIsCaught() {
        var nine = ansungOut()
        nine.holes[0].par = 5
        let card = CourseCard(courseName: "x", unit: "yards", nines: [nine])
        XCTAssertTrue(card.issues().contains { $0.kind == .parSumMismatch })
    }

    /// Handicaps are an allocation, so on a full 18 they are a permutation of 1…18.
    /// A repeat is a misread column, not a quirky course.
    func testRepeatedHandicapsOnAFullEighteenAreCaught() {
        var holes: [CourseCard.CardHole] = []
        for i in 1...18 {
            holes.append(.init(ref: "\(i)", par: 4, handicap: min(i, 17),
                               tees: [.init(name: "B", distance: 350)]))
        }
        let card = CourseCard(courseName: "x", unit: "metres",
                              nines: [.init(name: nil, holes: holes)])
        XCTAssertTrue(card.issues().contains { $0.kind == .handicapNotAPermutation })
    }

    func testDuplicateHoleNumbersWithoutANineNameAreCaught() {
        let h = CourseCard.CardHole(ref: "1", par: 4, tees: [])
        let card = CourseCard(courseName: "x", unit: "metres",
                              nines: [.init(name: nil, holes: [h]),
                                      .init(name: nil, holes: [h])])
        XCTAssertTrue(card.issues().contains { $0.kind == .duplicateRef })
    }

    // MARK: - Named nines

    func testHolesInDifferentNinesDoNotCollide() throws {
        func nine(_ name: String, par: Int) -> CourseCard.Nine {
            .init(name: name, holes: (1...9).map { (i: Int) -> CourseCard.CardHole in
                .init(ref: "\(i)", par: par, handicap: i,
                      tees: [.init(name: "White", distance: 350)])
            })
        }
        // 천룡CC's layout: three nines, each numbered 1–9.
        let card = CourseCard(courseName: "천룡CC", unit: "metres",
                              nines: [nine("황룡", par: 4), nine("청룡", par: 5), nine("흑룡", par: 3)])
        let course = card.course(id: "cheonryong", unit: .metres)

        XCTAssertEqual(course.holes.count, 27)
        XCTAssertEqual(Set(course.holes.map(\.id)).count, 27, "ids must be unique across nines")
        XCTAssertEqual(course.nines, ["황룡", "청룡", "흑룡"], "nine order follows the card")
        XCTAssertEqual(course.hole("황룡/1")?.par, 4)
        XCTAssertEqual(course.hole("청룡/1")?.par, 5)
        XCTAssertEqual(course.holes(nine: "흑룡").count, 9)
    }

    // MARK: - A card-only hole

    func testACardOnlyHoleHasNumbersAndNoGeometry() throws {
        let card = CourseCard(courseName: "안성CC", unit: "yards", nines: [ansungOut()])
        let course = card.course(id: "ansung-cc", unit: .yards)
        let h = try XCTUnwrap(course.hole(nine: "OUT", ref: "1"))

        XCTAssertFalse(h.hasGeometry)
        XCTAssertNil(h.geometry(), "no coordinates means no plane — not a plane at (0,0)")
        XCTAssertNil(h.bearing())
        XCTAssertNil(h.distances(from: Coordinate(lat: 37.4, lon: 127.2)))
        XCTAssertFalse(h.isOnGreen(Coordinate(lat: 37.4, lon: 127.2)))
        XCTAssertNil(h.elevationDelta(from: Coordinate(lat: 37.4, lon: 127.2)))

        // But the numbers a golfer reads are all there.
        XCTAssertEqual(h.par, 4)
        XCTAssertEqual(h.handicap, 4)
        XCTAssertEqual(try XCTUnwrap(h.length()), 350.2, accuracy: 0.2)
        XCTAssertEqual(course.holesWithoutGeometry.count, 9)
        XCTAssertFalse(course.hasGeometry)
    }

    /// The sample course has both, which is the normal state after an import plus
    /// some placement — and `length` must prefer the card over the measurement.
    func testLengthPrefersTheCardAndDisagreementIsMeasurable() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        let g = try XCTUnwrap(h.geometry())
        XCTAssertEqual(g.length, g.tee.distance, "the card number is the one on the tee sign")
        XCTAssertEqual(try XCTUnwrap(g.lengthDisagreement), 0, accuracy: 2,
                       "sample geometry and sample card are built from the same numbers")

        // Move the green 60 m and the disagreement must show up — this is the check
        // the editor uses to catch a point dropped on the wrong hole.
        var moved = h
        moved.green.center = SampleCourse.step(h.green.center!, h.bearing()!, 60)
        let g2 = try XCTUnwrap(moved.geometry())
        XCTAssertEqual(try XCTUnwrap(g2.lengthDisagreement), 60, accuracy: 3)
    }

    // MARK: - Re-importing a card over placed geometry

    /// The expensive asset is the coordinates, not the card. A second import must
    /// never cost someone their placement work.
    func testReimportingACardKeepsPlacedCoordinates() throws {
        let placedTee = Coordinate(lat: 37.4001, lon: 127.2001)
        let placedGreen = Coordinate(lat: 37.4035, lon: 127.2044)
        let existing = Course(
            id: "ansung-cc", name: "안성CC", source: .traced, cardUnit: .yards,
            holes: [Hole(ref: "1", nine: "OUT", par: 4, handicap: 4,
                         tees: [TeeBox(name: "Back", at: placedTee, distance: 350.2),
                                TeeBox(name: "Members", at: placedTee)],
                         green: Green(center: placedGreen)),
                    Hole(ref: "1", nine: "IN", par: 4, handicap: 9,
                         tees: [TeeBox(name: "Back", at: placedTee, distance: 374.9)],
                         green: Green(center: placedGreen))])

        // A fresh card for OUT only, with a corrected par on hole 1.
        var nine = ansungOut()
        nine.holes[0].par = 5
        nine.printedPar = 37
        let fresh = CourseCard(courseName: "안성 컨트리클럽", aliases: ["Ansung CC"],
                               unit: "yards", nines: [nine])
            .course(id: "ansung-cc", unit: .yards)

        let merged = existing.merging(card: fresh)

        let out1 = try XCTUnwrap(merged.hole("OUT/1"))
        XCTAssertEqual(out1.par, 5, "the card is authoritative for par")
        XCTAssertEqual(out1.green.center, placedGreen, "a placed green must survive re-import")
        XCTAssertEqual(out1.tee(named: "Back")?.at, placedTee, "a placed tee must survive")
        XCTAssertNotNil(out1.tee(named: "Members"),
                        "a tee that exists only in the placed file must not be dropped")
        XCTAssertTrue(out1.hasGeometry)

        XCTAssertNotNil(merged.hole("IN/1"),
                        "importing one nine must not delete the others")
        XCTAssertEqual(merged.name, "안성 컨트리클럽")
        XCTAssertTrue(merged.aliases.contains("Ansung CC"))
        XCTAssertEqual(merged.source, .traced,
                       "a file that already has geometry keeps its provenance")
    }

    func testMergingIntoAnEmptyCourseJustTakesTheCard() throws {
        let empty = Course(id: "x", name: "x", source: .card)
        let fresh = CourseCard(courseName: "안성CC", unit: "yards", nines: [ansungOut()])
            .course(id: "x", unit: .yards)
        let merged = empty.merging(card: fresh)
        XCTAssertEqual(merged.holes.count, 9)
        XCTAssertEqual(merged.source, .card)
    }

    // MARK: - No tee may answer with another tee's numbers

    /// A tee added in the editor has a name and nothing else. Asking it for a
    /// distance or a position must say "I don't know", not hand back the Back
    /// tee's — the screen is labelled with *this* tee.
    func testAnUnplacedTeeDoesNotBorrowAnotherTeesData() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        var withMembers = h
        withMembers.tees.append(TeeBox(name: "members"))
        let members = try XCTUnwrap(withMembers.tee(named: "members"))

        XCTAssertNil(withMembers.cardLength(from: members),
                     "an unplaced tee with no card number must read as unknown")
        XCTAssertNil(withMembers.geometry(tee: members),
                     "a tee with no coordinate must not be drawn from another tee's position")
        XCTAssertNil(withMembers.bearing(from: members))

        // The placed tees are unaffected.
        let white = try XCTUnwrap(withMembers.tee(named: "white"))
        XCTAssertNotNil(withMembers.geometry(tee: white))
        XCTAssertEqual(withMembers.geometry(tee: white)?.tee.name, "white")
    }

    // MARK: - The unit guess, against real cards

    /// Why the unit is assumed rather than inferred, as an executable argument.
    ///
    /// Every real total below is *plausible* — none is flagged — and yet they are
    /// not all the same unit. 도고 (metres, 91.0 per par) sits between 서울한양
    /// (yards, 89.9) and 천룡 (yards, 96.0), and Angeles National's White tee
    /// (yards, 85.7) sits below all of them. No cut through this line separates the
    /// units, which is exactly why `plausibility` returns a note and never an answer.
    func testNoTotalBasedRuleSeparatesTheUnits() {
        let cards: [(String, Double, Int)] = [
            ("서울한양 (yards)", 6475, 72),
            ("도고 (METRES)", 6556, 72),
            ("천룡 (yards)", 6914, 72),
            ("안성 (yards)", 7067, 72),
            ("Angeles National, White (yards)", 6169, 72),
            ("Angeles National, Black (yards)", 7141, 72),
        ]
        for (name, total, par) in cards {
            XCTAssertNil(DistanceUnit.plausibility(total: total, par: par),
                         "\(name) is an ordinary course and must not be flagged")
        }
        // 도고 is metres and sits *between* two yards cards. Any threshold that
        // calls 천룡 yards also calls 도고 yards, and shrinks it 8.5%.
        XCTAssertTrue(6475 / 72.0 < 6556 / 72.0 && 6556 / 72.0 < 6914 / 72.0,
                      "the metric card is bracketed by two imperial ones")
    }

    // MARK: - American card conventions

    /// Angeles National, verbatim. Men's and women's stroke indexes are different
    /// allocations, and one `handicap` field would silently take a column: both rows
    /// are a valid 1…18 permutation, so nothing downstream could tell.
    func testBothHandicapAllocationsSurviveAndAreCheckedSeparately() throws {
        let mens =   [15, 5, 7, 17, 9, 3, 13, 11, 1, 12, 18, 16, 14, 8, 2, 6, 10, 4]
        let womens = [11, 7, 17, 15, 5, 1, 13, 9, 3, 12, 18, 16, 14, 8, 2, 6, 10, 4]
        let pars =   [4, 5, 3, 4, 4, 4, 3, 5, 4, 4, 4, 3, 5, 3, 4, 5, 4, 4]
        let black =  [402.0, 585, 212, 427, 422, 459, 176, 530, 486,
                      459, 310, 130, 494, 218, 472, 537, 406, 416]
        let holes = (0..<18).map { i in
            CourseCard.CardHole(ref: "\(i + 1)", par: pars[i],
                                handicap: mens[i], handicapWomen: womens[i],
                                tees: [.init(name: "Black", distance: black[i],
                                             rating: 74.7, slope: 143)])
        }
        let card = CourseCard(courseName: "Angeles National Golf Club", unit: "unknown",
                              nines: [.init(name: nil, holes: holes,
                                            printedPar: 72,
                                            printedTees: [.init(name: "Black", distance: 7141)])])
        XCTAssertEqual(card.issues(), [], "a verbatim real American card must reconcile: \(card.issues())")

        let course = card.course(id: "angeles-national", unit: .yards)
        let h1 = try XCTUnwrap(course.hole("1"))
        XCTAssertEqual(h1.handicap, 15)
        XCTAssertEqual(h1.handicapWomen, 11, "the women's row must not be overwritten by the men's")
        XCTAssertEqual(h1.tees[0].rating, 74.7)
        XCTAssertEqual(h1.tees[0].slope, 143)
        XCTAssertEqual(try XCTUnwrap(h1.cardLength()), 367.6, accuracy: 0.2, "402 yd in metres")
    }

    /// A misread women's column must be caught on its own, not hidden behind a
    /// valid men's row.
    func testAMisreadWomensColumnIsCaughtIndependently() {
        var holes: [CourseCard.CardHole] = []
        for i in 1...18 {
            holes.append(.init(ref: "\(i)", par: 4, handicap: i,
                               handicapWomen: min(i, 17),
                               tees: [.init(name: "Back", distance: 350)]))
        }
        let card = CourseCard(courseName: "x", unit: "unknown",
                              nines: [.init(name: nil, holes: holes)])
        let issues = card.issues()
        XCTAssertTrue(issues.contains { $0.kind == .handicapNotAPermutation
                                        && $0.detail.contains("women") },
                      "the women's row must be checked separately: \(issues)")
    }

    // MARK: - The schema ↔ DTO contract

    /// The one part of the importer that cannot be exercised without an API key is
    /// the model call; this closes everything on the near side of it. The fixture
    /// is shaped exactly as `Prompts/course-card.schema.json` describes, nulls
    /// included, because a schema the DTO cannot decode fails on the user's first
    /// real card with no test firing.
    ///
    /// Kept as a literal on purpose: reading `Prompts/` from the test target would
    /// need `resources:`, which generates `Bundle.module` and is banned (CLAUDE.md).
    func testTheExtractionSchemaShapeDecodesAndFlowsThrough() throws {
        let json = """
        {
          "courseName": "천룡CC",
          "aliases": ["Cheonryong CC"],
          "unit": "unknown",
          "nines": [
            {
              "name": "황룡",
              "holes": [
                {"ref": "1", "par": 4, "handicap": 6,
                 "tees": [{"name": "Black", "distance": 395}, {"name": "Red", "distance": 309}]},
                {"ref": "2", "par": 3, "handicap": null,
                 "tees": [{"name": "Black", "distance": null}, {"name": "Red", "distance": 90}]}
              ],
              "printedPar": 7,
              "printedTees": [{"name": "Black", "distance": 395}]
            },
            {
              "name": null,
              "holes": [{"ref": "9A", "par": 5, "handicap": 1, "tees": []}],
              "printedPar": null,
              "printedTees": []
            }
          ],
          "notes": null
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder().decode(CourseCard.self, from: json)
        XCTAssertEqual(card.courseName, "천룡CC")
        XCTAssertEqual(card.unit, "unknown")
        XCTAssertNil(card.declaredUnit)
        XCTAssertNil(card.notes)
        XCTAssertEqual(card.nines.count, 2)
        XCTAssertNil(card.nines[1].name, "an unnamed nine must decode as nil, not \"null\"")
        XCTAssertNil(card.nines[0].holes[1].handicap)
        XCTAssertEqual(card.nines[0].holes[0].tees.first { $0.name == "Black" }?.distance, 395)
        XCTAssertNil(card.nines[0].holes[1].tees[0].distance, "a null distance must survive as nil")

        // …and all the way through to a Course.
        let course = card.course(id: "cheonryong", unit: .metres)
        XCTAssertEqual(course.holes.count, 3)
        XCTAssertEqual(course.hole("황룡/1")?.par, 4)
        XCTAssertEqual(course.hole("9A")?.par, 5, "an unnamed nine keys on the bare ref")
        XCTAssertEqual(course.nines, ["황룡"])
        XCTAssertFalse(course.hasGeometry)

        // The reconciler must survive the ragged shape rather than trap on it, and
        // must not invent problems: 4+3 really is the printed 7, and Black's 395
        // really is the printed total once the null hole contributes nothing.
        let issues = card.issues()
        XCTAssertTrue(issues.contains { $0.kind == .holeCount }, "2 and 1 holes are not 9 or 18")
        XCTAssertFalse(issues.contains { $0.kind == .parSumMismatch }, "\(issues)")
        XCTAssertFalse(issues.contains { $0.kind == .teeSumMismatch }, "\(issues)")
        XCTAssertFalse(issues.contains(where: \.blocking),
                       "a thin card is a warning, not a refusal: \(issues)")
    }

    /// Under the US flow the ordinary file is OSM geometry with a website card
    /// imported over it. A hole records one source, so the licensing-relevant one
    /// must win — overwriting `.osm` with `.card` would erase the share-alike
    /// obligation on the hole that carries it.
    func testACardImportOverOSMGeometryKeepsTheODbLMarking() throws {
        let osm = Course(
            id: "angeles-national", name: "Angeles National", source: .osm,
            attribution: "© OpenStreetMap contributors",
            holes: [Hole(ref: "1", par: 4, handicap: 99, handicapWomen: 99,
                         tees: [TeeBox(name: "Black", at: Coordinate(lat: 34.3, lon: -118.2))],
                         green: Green(center: Coordinate(lat: 34.305, lon: -118.205)),
                         source: .osm)])

        let card = CourseCard(courseName: "Angeles National Golf Club", unit: "unknown",
                              nines: [.init(name: nil, holes: [
                                  .init(ref: "1", par: 4, handicap: 15, handicapWomen: 11,
                                        tees: [.init(name: "Black", distance: 402,
                                                     rating: 74.7, slope: 143)])])])
            .course(id: "angeles-national", unit: .yards)

        let merged = osm.merging(card: card)
        let h = try XCTUnwrap(merged.hole("1"))

        XCTAssertEqual(h.source, .osm, "the ODbL marking must survive a card import over it")
        XCTAssertEqual(h.handicap, 15, "the card is authoritative for the men's index")
        XCTAssertEqual(h.handicapWomen, 11, "and for the women's — a stale row must not survive")
        XCTAssertEqual(h.tees[0].slope, 143)
        XCTAssertNotNil(h.tees[0].at, "OSM's coordinates must survive")
        XCTAssertTrue(h.hasGeometry)
    }
}

/// One added field made every course file already on disk unreadable, and it was
/// found by running the CLI rather than by reading the diff. `Hole.paths` is stored
/// as an optional for exactly that reason.
final class HoleSchemaCompatibilityTests: XCTestCase {

    func testAHoleWithNoPathsKeyStillDecodes() throws {
        let json = """
        {"ref":"1","par":4,"tees":[],"green":{"polygon":[]},"line":[],"fairway":[],"hazards":[]}
        """.data(using: .utf8)!
        let h = try JSONDecoder().decode(Hole.self, from: json)
        XCTAssertEqual(h.ref, "1")
        XCTAssertTrue(h.paths.isEmpty)
    }

    /// …and a hole with none encodes exactly as it did before the field existed, so
    /// re-writing a course file does not churn every hole in it.
    func testAHoleWithNoPathsEncodesNoPathsKey() throws {
        let data = try JSONEncoder().encode(Hole(ref: "1", par: 4))
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("paths"))
    }

    func testPathsRoundTrip() throws {
        let line = [Coordinate(lat: 1, lon: 2), Coordinate(lat: 1.001, lon: 2.001)]
        let h = Hole(ref: "1", par: 4, paths: [line])
        let back = try JSONDecoder().decode(Hole.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.paths.count, 1)
        XCTAssertEqual(back.paths[0].count, 2)
    }
}
