// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class IXMLTests: XCTestCase {
    // INTERLEAVE_INDEX (position in the interleaved file) is the mapping key.
    func testInterleaveIndexMapping() {
        let xml = """
        <BWFXML><TRACK_LIST><TRACK_COUNT>2</TRACK_COUNT>
        <TRACK><CHANNEL_INDEX>5</CHANNEL_INDEX><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Boom</NAME></TRACK>
        <TRACK><CHANNEL_INDEX>6</CHANNEL_INDEX><INTERLEAVE_INDEX>2</INTERLEAVE_INDEX><NAME>Lav</NAME></TRACK>
        </TRACK_LIST></BWFXML>
        """
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [1: "Boom", 2: "Lav"])
    }

    // Falls back to CHANNEL_INDEX when INTERLEAVE_INDEX is absent.
    func testChannelIndexFallback() {
        let xml = "<TRACK_LIST><TRACK><CHANNEL_INDEX>3</CHANNEL_INDEX><NAME>Kick</NAME></TRACK></TRACK_LIST>"
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [3: "Kick"])
    }

    // Falls back to track order when neither index is present.
    func testOrderFallbackWhenNoIndex() {
        let xml = "<TRACK_LIST><TRACK><NAME>One</NAME></TRACK><TRACK><NAME>Two</NAME></TRACK></TRACK_LIST>"
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [1: "One", 2: "Two"])
    }

    func testEntityDecoding() {
        let xml = "<TRACK_LIST><TRACK><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Boom &amp; Mic</NAME></TRACK></TRACK_LIST>"
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [1: "Boom & Mic"])
    }

    // Empty names are skipped (order still advances for the following tracks).
    func testEmptyNameSkipped() {
        let xml = """
        <TRACK_LIST>
        <TRACK><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME></NAME></TRACK>
        <TRACK><INTERLEAVE_INDEX>2</INTERLEAVE_INDEX><NAME>Vox</NAME></TRACK>
        </TRACK_LIST>
        """
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [2: "Vox"])
    }

    func testNoTrackListReturnsEmpty() {
        XCTAssertTrue(ixmlTrackNames(fromXML: "<BWFXML><PROJECT>Show</PROJECT></BWFXML>").isEmpty)
    }

    // Tag attributes and surrounding whitespace must not break extraction.
    func testAttributesAndWhitespaceTolerated() {
        let xml = """
        <TRACK_LIST>
          <TRACK id="a"><INTERLEAVE_INDEX> 2 </INTERLEAVE_INDEX><NAME xml:lang="en">  OH L  </NAME></TRACK>
        </TRACK_LIST>
        """
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [2: "OH L"])
    }

    // TRACK_COUNT must not be mistaken for a TRACK entry.
    func testTrackCountNotTreatedAsTrack() {
        let xml = """
        <TRACK_LIST><TRACK_COUNT>1</TRACK_COUNT>
        <TRACK><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Snare</NAME></TRACK></TRACK_LIST>
        """
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [1: "Snare"])
    }

    // Numeric character references (decimal and hex) decode.
    func testNumericEntityDecoding() {
        let xml = "<TRACK_LIST><TRACK><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Caf&#233; &#x4D;ic</NAME></TRACK></TRACK_LIST>"
        XCTAssertEqual(ixmlTrackNames(fromXML: xml), [1: "Café Mic"])
    }

    // MARK: - Write path

    // A mono name written out is read back unchanged.
    func testMonoRoundTrip() {
        let xml = ixmlDocument(forTrackNames: ["Kick"])
        XCTAssertNotNil(xml)
        XCTAssertEqual(ixmlTrackNames(fromXML: xml ?? ""), [1: "Kick"])
    }

    // Stereo writes two L/R tracks, recovered as positions 1 and 2.
    func testStereoRoundTrip() {
        let xml = ixmlDocument(forTrackNames: ["OH_L", "OH_R"])
        XCTAssertEqual(ixmlTrackNames(fromXML: xml ?? ""), [1: "OH L", 2: "OH R"])
    }

    // Special characters survive a write/read round-trip via entity encoding.
    func testNameWithEntitiesRoundTrip() {
        let xml = ixmlDocument(forTrackNames: ["A & B <2>"])
        XCTAssertEqual(ixmlTrackNames(fromXML: xml ?? ""), [1: "A & B <2>"])
    }

    // No name on either side → no document (and so no chunk is written).
    func testNoNameProducesNoDocument() {
        XCTAssertNil(ixmlDocument(forTrackNames: [""]))
        XCTAssertNil(ixmlDocument(forTrackNames: ["", ""]))
    }

    // Stereo base derivation: shared L/R suffix, single named side, and none.
    func testStereoLabels() {
        XCTAssertEqual(stereoLabels(left: "OH_L", right: "OH_R").map { [$0.0, $0.1] }, ["OH L", "OH R"])
        XCTAssertEqual(stereoLabels(left: "OH", right: "").map { [$0.0, $0.1] }, ["OH L", "OH R"])
        XCTAssertEqual(stereoLabels(left: "", right: "OH-R").map { [$0.0, $0.1] }, ["OH L", "OH R"])
        XCTAssertNil(stereoLabels(left: "", right: ""))
    }

    // Two genuinely different names on a pair are both kept, not collapsed to one base.
    func testStereoLabelsPreservesDistinctNames() {
        XCTAssertEqual(stereoLabels(left: "Boom", right: "Lav").map { [$0.0, $0.1] }, ["Boom", "Lav"])
        let xml = ixmlDocument(forTrackNames: ["Boom", "Lav"])
        XCTAssertEqual(ixmlTrackNames(fromXML: xml ?? ""), [1: "Boom", 2: "Lav"])
    }
}
