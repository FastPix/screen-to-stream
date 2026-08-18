import XCTest
@testable import App

@MainActor
final class AppStateTests: XCTestCase {
    func testStartsOnPermissionsAndAdvances() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        XCTAssertEqual(state.screen, .permissions)
        state.permissionsSatisfied()
        XCTAssertEqual(state.screen, .sourcePicker)
        state.showPermissions()
        XCTAssertEqual(state.screen, .permissions)
    }

    func testCancellingCountdownReturnsToPicker() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.cancelCountdown()
        XCTAssertEqual(state.screen, .sourcePicker)
    }

    func testDiscardingRecordingDeletesFileAndReturnsToPicker() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-test-\(UUID().uuidString).mov")
        try Data("x".utf8).write(to: url)

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.discardRecording(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(state.screen, .sourcePicker)
    }

    func testShowingPickerClearsEndedEarlyNotice() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.endedEarlyNotice = "Recording ended early: stream failed"
        state.showSourcePicker()
        XCTAssertNil(state.endedEarlyNotice)
    }

    func testShowingPickerClearsReviewTrim() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        var trim = TrimRange(duration: 20)
        trim.moveStart(to: 2)
        state.reviewTrim = trim
        state.showSourcePicker()
        XCTAssertNil(state.reviewTrim)
    }

    func testDiscardingRecordingClearsReviewTrim() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-discard-\(UUID().uuidString).mov")
        try Data("x".utf8).write(to: url)

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.reviewTrim = TrimRange(duration: 20)
        state.discardRecording(at: url)
        XCTAssertNil(state.reviewTrim)
    }

    func testRemoveFromLibraryDeletesEntryAndFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString).mov")
        try Data("v".utf8).write(to: url)

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        let entry = HistoryEntry.local(id: "e1", fileURL: url, durationSec: nil, thumbnailPath: nil)
        state.history.add(entry)

        state.removeFromLibrary(entry)

        XCTAssertNil(state.history.entry(id: "e1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testResumeResetsInterruptedUploadToLocal() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        var entry = HistoryEntry.local(id: "e1", fileURL: URL(fileURLWithPath: "/tmp/x.mov"),
                                       durationSec: nil, thumbnailPath: nil)
        entry.status = "uploading"
        state.history.add(entry)

        state.resumeInterrupted()

        XCTAssertEqual(state.history.entry(id: "e1")?.statusValue, .local)
    }

    func testResumeRepollsProcessingToReady() async throws {
        // FastPixAPI's default authProvider reads the real Keychain; without a credential the
        // request throws .unauthenticated before it ever reaches the stub. Give it a test
        // credential (isolated service) so the stubbed session is actually exercised — otherwise
        // this passes only on a machine that happens to have FastPix creds saved (e.g. locally)
        // and fails on a clean CI keychain.
        CredentialStore.serviceOverride = "com.fastpix.screen-to-stream.tests"
        try CredentialStore.save(FastPixCredentials(tokenId: "t", secret: "s"))
        defer { CredentialStore.clear(); CredentialStore.serviceOverride = nil }

        StubURLProtocol.reset()
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}]}}"#)

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.apiSession = StubURLProtocol.session()
        state.pollSleeper = { _ in }
        var entry = HistoryEntry.local(id: "e1", fileURL: URL(fileURLWithPath: "/tmp/x.mov"),
                                       durationSec: nil, thumbnailPath: nil)
        entry.status = "processing"; entry.mediaId = "m1"
        state.history.add(entry)

        state.resumeInterrupted()

        for _ in 0..<100 {
            if state.history.entry(id: "e1")?.statusValue == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.history.entry(id: "e1")?.statusValue, .ready)
        XCTAssertEqual(state.history.entry(id: "e1")?.playbackId, "pb_1")
    }

    func testDeleteFromFastPixTreatsNotFoundAsSuccess() async throws {
        // See testResumeRepollsProcessingToReady: without a credential the delete throws
        // .unauthenticated before reaching the stub, so the 404-is-success path is never
        // exercised on a clean CI keychain. Inject a test credential to make it hermetic.
        CredentialStore.serviceOverride = "com.fastpix.screen-to-stream.tests"
        try CredentialStore.save(FastPixCredentials(tokenId: "t", secret: "s"))
        defer { CredentialStore.clear(); CredentialStore.serviceOverride = nil }

        StubURLProtocol.reset()
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 404,
            json: #"{"success":false,"error":{"message":"media workspace relation not found"}}"#)

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.apiSession = StubURLProtocol.session()
        var entry = HistoryEntry.local(id: "e1", fileURL: URL(fileURLWithPath: "/tmp/x.mov"),
                                       durationSec: nil, thumbnailPath: nil)
        entry.status = "ready"; entry.mediaId = "m1"; entry.playbackId = "pb"
        state.history.add(entry)

        state.deleteFromFastPix(entry)

        for _ in 0..<100 {
            if state.history.entry(id: "e1") == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(state.history.entry(id: "e1"))   // removed despite the 404
        XCTAssertNil(state.libraryError)               // and no error surfaced
    }

    func testKeepInLibraryNavigatesAndClearsReview() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.reviewTrim = TrimRange(duration: 10)
        state.keepInLibrary()
        XCTAssertEqual(state.screen, .library)
        XCTAssertNil(state.reviewTrim)
    }

    func testShowAndCloseSettingsRoundTrips() {
        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.permissionsSatisfied()
        XCTAssertEqual(state.screen, .sourcePicker)
        state.showSettings()
        XCTAssertEqual(state.screen, .settings)
        state.closeSettings()
        XCTAssertEqual(state.screen, .sourcePicker)
    }

    func testUploadWithoutCredentialsRoutesToSettings() async throws {
        CredentialStore.serviceOverride = "com.fastpix.screen-to-stream.tests"
        CredentialStore.clear()
        defer { CredentialStore.clear(); CredentialStore.serviceOverride = nil }

        StubURLProtocol.reset()
        // The resumed upload will create → 404 → fail fast; scripting it keeps the
        // background task deterministic so it doesn't leak into other tests' stub state.
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 404, json: "{}")

        let state = AppState(historyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)"))
        state.apiSession = StubURLProtocol.session()   // never touch the real API in tests
        XCTAssertFalse(state.hasCredentials)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString).mov")
        try Data("v".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        state.beginUpload(entryId: "e1", fileURL: url, trim: nil)
        XCTAssertEqual(state.screen, .settings)

        // Saving credentials resumes the pending upload.
        try CredentialStore.save(FastPixCredentials(tokenId: "t", secret: "s"))
        state.refreshCredentials()
        XCTAssertEqual(state.screen, .uploading)

        // Drain the resumed upload's background task so it can't pollute later tests.
        try await drainUntilTerminal(state)
    }

    private func drainUntilTerminal(_ state: AppState) async throws {
        for _ in 0..<100 {
            if case .failed = state.uploadCoordinator?.phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRecordingURLLandsInMoviesFolderWithTimestamp() {
        let url = AppState.newRecordingURL()
        XCTAssertEqual(url.pathExtension, "mov")
        XCTAssertTrue(url.path.contains("ScreenToStream"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Recording-"))
    }
}
