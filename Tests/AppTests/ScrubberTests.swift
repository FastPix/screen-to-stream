import XCTest
@testable import App

final class ScrubberTests: XCTestCase {
    func testRedactsBasicAuthHeader() {
        XCTAssertEqual(LogScrubber.scrub("Authorization: Basic dG9rZW46c2VjcmV0"),
                       "Authorization: <redacted>")
    }

    func testRedactsKeyValueSecrets() {
        for key in ["token", "secret", "tokenId", "password", "authorization"] {
            let scrubbed = LogScrubber.scrub("\(key)=abc123XYZ")
            XCTAssertFalse(scrubbed.contains("abc123XYZ"), key)
        }
    }

    func testRedactsLongOpaqueStrings() {
        let scrubbed = LogScrubber.scrub("upload failed id=9f8e7d6c5b4a39281706f5e4d3c2b1a0")
        XCTAssertFalse(scrubbed.contains("9f8e7d6c5b4a39281706f5e4d3c2b1a0"))
    }

    func testLeavesNormalTextAlone() {
        XCTAssertEqual(LogScrubber.scrub("started recording display 1"),
                       "started recording display 1")
    }

    func testLeavesRecordingFilenameReadable() {
        let line = "FileSink finished → /Users/x/Movies/ScreenToStream/Recording-2026-08-11-110413.mov"
        XCTAssertEqual(LogScrubber.scrub(line), line)
    }

    func testLeavesPreparedAndMediaFilenamesReadable() {
        let line = "prepared single-audio-track asset → prepared-671B7A66-2C7D-4AFA-9868-133A97BD460B.mov"
        XCTAssertEqual(LogScrubber.scrub(line), line)
    }
}
