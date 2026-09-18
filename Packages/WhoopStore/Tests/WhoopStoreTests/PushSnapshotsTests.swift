import XCTest
import WhoopProtocol
@testable import WhoopStore

final class PushSnapshotsTests: XCTestCase {
    func testAppendProjectionUsesRowIdAndOmitsLocalSyncedColumn() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "dev")

        let rows = try await store.pushAppendRecords(table: .hrSample, deviceId: "dev", afterRowId: 0, limit: 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].rowId)
        XCTAssertEqual(rows[0].key, ["ts": .integer(100)])
        XCTAssertEqual(rows[0].data, ["bpm": .integer(60)])
    }

    func testKnownDeviceIdsIncludesDevicesWithOnlyMutableRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        try await store.upsertJournal([JournalEntry(day: "2026-09-17", question: "water", answeredYes: true, notes: nil)], deviceId: "dev")

        let ids = try await store.pushKnownDeviceIds()
        XCTAssertEqual(ids, ["dev"])
    }
}
