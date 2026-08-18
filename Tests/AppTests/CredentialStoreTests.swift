import XCTest
@testable import App

final class CredentialStoreTests: XCTestCase {
    override func setUp() {
        CredentialStore.serviceOverride = "com.fastpix.screen-to-stream.tests"
        CredentialStore.clear()
    }

    override func tearDown() {
        CredentialStore.clear()
        CredentialStore.serviceOverride = nil
    }

    func testSaveThenLoadRoundTrips() throws {
        try CredentialStore.save(FastPixCredentials(tokenId: "tok", secret: "sec"))
        XCTAssertEqual(CredentialStore.load(), FastPixCredentials(tokenId: "tok", secret: "sec"))
    }

    func testClearRemoves() throws {
        try CredentialStore.save(FastPixCredentials(tokenId: "tok", secret: "sec"))
        CredentialStore.clear()
        XCTAssertNil(CredentialStore.load())
    }

    func testOverwriteReplaces() throws {
        try CredentialStore.save(FastPixCredentials(tokenId: "a", secret: "1"))
        try CredentialStore.save(FastPixCredentials(tokenId: "b", secret: "2"))
        XCTAssertEqual(CredentialStore.load()?.tokenId, "b")
        XCTAssertEqual(CredentialStore.load()?.secret, "2")
    }

    func testBasicAuthHeaderNilWhenEmpty() {
        XCTAssertNil(CredentialStore.basicAuthHeader)
    }

    func testBasicAuthHeaderEncodesColonJoined() throws {
        try CredentialStore.save(FastPixCredentials(tokenId: "tok", secret: "sec"))
        let expected = "Basic " + Data("tok:sec".utf8).base64EncodedString()
        XCTAssertEqual(CredentialStore.basicAuthHeader, expected)
    }
}
