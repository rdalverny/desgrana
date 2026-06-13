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
}
