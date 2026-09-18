import XCTest
@testable import Strand

final class SelfHostedPushBackupTests: XCTestCase {
    func testBackupEndpointIsExplicit() {
        let backupResult = SelfHostedPushEndpointPolicy.validate("https://example.com/api/backup")
        let structuredResult = SelfHostedPushEndpointPolicy.validate("https://example.com/noop-sync")
        guard case let (.success(backup), .success(structured)) = (backupResult, structuredResult) else {
            return XCTFail("fixtures should be valid endpoints")
        }
        XCTAssertTrue(SelfHostedPush.isBackupEndpoint(backup))
        XCTAssertFalse(SelfHostedPush.isBackupEndpoint(structured))
    }
}
