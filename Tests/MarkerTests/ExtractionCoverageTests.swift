import XCTest
@testable import GolfSessionFormat

/// The runaway reported on device 2026-08-27: a typed sentence with no shot in it
/// was handed to Apple Intelligence over and over, appending garbage each pass.
final class ExtractionCoverageTests: XCTestCase {

    private func log(_ text: String, id: String) -> LogEntry {
        LogEntry(id: id, t: 1000, text: text, source: .typed)
    }

    /// The bug in one test. "Players are A, B, C, D" is a real observation with no
    /// shot and no score in it, so extraction proposes nothing, so **nothing cites
    /// it** — and a citation check therefore reports it as unread forever.
    func testALogThatProducedNoProposalIsStillMarkedRead() {
        let l = log("players are A, B, C, D", id: "lg0")
        var coverage = ExtractionCoverage()

        XCTAssertEqual(coverage.unread([l], cited: []).map(\.id), ["lg0"])
        coverage.mark([l], extractor: "test")
        XCTAssertTrue(coverage.unread([l], cited: []).isEmpty,
                      "read once, never re-read — no event cites it and none ever will")
    }

    /// Editing a log writes a superseding row with a **new** id, deliberately
    /// absent from coverage. Correcting a misheard name is the whole reason to
    /// edit, so the correction has to be read.
    func testAnEditedLogIsReadAgain() {
        let original = log("steve birdy", id: "a")
        var coverage = ExtractionCoverage()
        coverage.mark([original], extractor: "test")

        let edited = original.edited(text: "steve birdie", id: "b")!
        XCTAssertEqual(coverage.unread([edited]).map(\.id), ["b"],
                       "keying coverage on the chain root would silently ignore every edit")
    }

    /// A round extracted before this file existed has only its events to go on.
    func testCitationsStillCountSoAnOlderRoundIsNotReReadFromScratch() {
        let l = log("steve made five", id: "lg3")
        let coverage = ExtractionCoverage()
        XCTAssertTrue(coverage.unread([l], cited: ["lg3"]).isEmpty)
    }

    func testCoverageRecordsWhichExtractorProducedIt() {
        var coverage = ExtractionCoverage()
        coverage.mark([log("x", id: "a")], extractor: "foundationmodels-ondevice")
        XCTAssertEqual(coverage.extractor, "foundationmodels-ondevice",
                       "the cloud pass must not be served the on-device pass's cache")
    }

    func testMarkingIsCumulative() {
        var coverage = ExtractionCoverage()
        coverage.mark([log("a", id: "a")], extractor: "t")
        coverage.mark([log("b", id: "b")], extractor: "t")
        XCTAssertEqual(coverage.logs, ["a", "b"])
    }

    /// It is bookkeeping about the machine, not a claim about the round, so it is
    /// in neither firewall set — same standing as `transcript.coverage.json`.
    func testCoverageIsNotGroundTruthAndNotMixed() {
        XCTAssertFalse(SessionFolder.File.extractionCoverage.isGroundTruth)
        XCTAssertFalse(SessionFolder.File.extractionCoverage.isMixedProvenance)
    }
}
