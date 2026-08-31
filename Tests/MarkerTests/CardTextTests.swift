import XCTest
@testable import GolfCourse

/// The HTML reduction that feeds every URL import. Each case here is a shape found
/// on a real published scorecard, not a hypothetical — and each one, left
/// unhandled, produces a card that looks right and is wrong.
final class CardTextTests: XCTestCase {

    /// angelesnational.com, verbatim: the men's stroke index for hole 4 is
    /// `1<span class="style1">7</span>`. Replacing inline tags with a space splits
    /// it into `1` and `7`, which shifts the whole row by one and still yields
    /// eighteen plausible stroke indexes.
    func testAnInlineTagInsideANumberDoesNotSplitIt() {
        let html = """
        <tr><td>Men&#8217;s Hcp</td><td>15</td><td>5</td><td>7</td>\
        <td>1<span class="style1">7</span></td><td>9</td></tr>
        """
        let cells = CardText.strip(html).split(separator: "\t").map(String.init)
        XCTAssertEqual(cells, ["Men\u{2019}s Hcp", "15", "5", "7", "17", "9"],
                       "17 must survive as one number")
    }

    /// The same page puts a newline between every `</td>` and the next `<td>`. If
    /// that survives, every cell becomes its own row and the table is gone.
    func testSourceNewlinesBetweenCellsDoNotBecomeRowBreaks() {
        let html = """
        <tr>
          <td>Par</td>
          <td>4</td>
          <td>5</td>
        </tr>
        <tr>
          <td>Black</td>
          <td>402</td>
          <td>585</td>
        </tr>
        """
        let rows = CardText.strip(html).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 2, "two <tr> must give two rows, got \(rows)")
        XCTAssertEqual(rows[0].split(separator: "\t").map(String.init), ["Par", "4", "5"])
        XCTAssertEqual(rows[1].split(separator: "\t").map(String.init), ["Black", "402", "585"])
    }

    /// An empty cell is information: it is why a totals column is blank on the
    /// handicap row. Collapsing it shifts every value after it.
    func testAnEmptyCellSurvivesAsAnEmptyColumn() {
        let html = "<tr><td>Hcp</td><td>15</td><td></td><td>7</td></tr>"
        let cells = CardText.strip(html).split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(cells.map(String.init), ["Hcp", "15", "", "7"])
    }

    func testNumericEntitiesDecode() {
        XCTAssertEqual(CardText.decodeEntities("Men&#8217;s Hcp"), "Men\u{2019}s Hcp")
        XCTAssertEqual(CardText.decodeEntities("&#x41;&#66;"), "AB")
        XCTAssertEqual(CardText.decodeEntities("Ladies &amp; Men"), "Ladies & Men")
        XCTAssertEqual(CardText.decodeEntities("100&#37 off"), "100&#37 off",
                       "an unterminated entity must be left alone, not swallowed")
        XCTAssertEqual(CardText.decodeEntities("&#99999999999;"), "&#99999999999;",
                       "an out-of-range code point must not crash or vanish")
    }

    func testScriptStyleAndHeadAreRemoved() {
        let html = """
        <head><title>Scorecard</title></head>
        <body><script>var par = [4,5,3];</script><style>td{color:red}</style>
        <table><tr><td>Par</td><td>4</td></tr></table></body>
        """
        let out = CardText.strip(html)
        XCTAssertFalse(out.contains("var par"), "script contents must not reach the model")
        XCTAssertFalse(out.contains("color:red"))
        XCTAssertTrue(out.contains("Par\t4"))
    }
}
