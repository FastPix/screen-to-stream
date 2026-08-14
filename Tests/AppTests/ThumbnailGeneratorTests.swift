import XCTest
import AppKit
@testable import App

final class ThumbnailGeneratorTests: XCTestCase {
    func testGeneratesAnImageFile() async throws {
        let video = try await VideoFixture.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: video) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true)
        let path = await ThumbnailGenerator.generate(from: video, id: "r1", directory: dir)

        let unwrapped = try XCTUnwrap(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped))
        XCTAssertNotNil(NSImage(contentsOfFile: unwrapped))
    }

    func testBogusURLReturnsNilWithoutThrowing() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true)
        let path = await ThumbnailGenerator.generate(
            from: URL(fileURLWithPath: "/nope/missing.mov"), id: "r1", directory: dir)
        XCTAssertNil(path)
    }
}
