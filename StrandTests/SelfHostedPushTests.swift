import XCTest
import WhoopStore
@testable import Strand

final class SelfHostedPushTests: XCTestCase {
    private let source = "00000000-0000-5000-8000-000000000001"

    private func validEndpoint(_ value: String) -> SelfHostedPushEndpointPolicy.Valid? {
        guard case .success(let endpoint) = SelfHostedPushEndpointPolicy.validate(value) else { return nil }
        return endpoint
    }

    func testEndpointPolicyRequiresTlsExceptNumericPrivateAddresses() {
        XCTAssertNotNil(validEndpoint("https://example.com/noop-sync"))
        XCTAssertNotNil(validEndpoint("http://192.168.1.10/noop-sync"))
        XCTAssertNil(validEndpoint("http://receiver.local/noop-sync"))
        XCTAssertNil(validEndpoint("https://user:secret@example.com"))
    }

    func testCapabilitiesFailClosedForUnknownDuplicateOrRemoteControlStreams() {
        let base = "\"type\":\"capabilities\",\"protocolVersion\":\"1.0\",\"receiverStateId\":\"00000000-0000-4000-8000-000000000001\""
        for streams in ["[\"hrSample\",\"hrSample\"]", "[\"unknown\"]"] {
            XCTAssertThrowsError(try SelfHostedPushCapabilities.parse(Data("{\(base),\"streams\":\(streams)}".utf8)))
        }
        XCTAssertThrowsError(try SelfHostedPushCapabilities.parse(Data("{\(base),\"streams\":[],\"command\":\"wipe\"}".utf8)))
    }

    func testAcknowledgementRequiresExactCursorCountAndStatus() throws {
        let record = PushStoreRecord(rowId: 9, key: ["ts": .integer(100)], data: ["bpm": .integer(60)])
        let batch = try SelfHostedPushCodec.appendBatch(stream: "hrSample", sourceId: source, deviceId: "dev", start: nil, records: [record])
        let ack = "{\"protocolVersion\":\"1.0\",\"batchId\":\"\(batch.batchId)\",\"stream\":\"hrSample\",\"deviceId\":\"dev\",\"endCursor\":{\"rowId\":9,\"keySha256\":\"\(batch.endCursor!.keySha256)\"},\"acceptedRows\":1,\"status\":\"accepted\"}"
        XCTAssertTrue(try SelfHostedPushAcknowledgement.parse(Data(ack.utf8)).matches(batch))
        let bad = ack.replacingOccurrences(of: "\"acceptedRows\":1", with: "\"acceptedRows\":2")
        XCTAssertFalse(try SelfHostedPushAcknowledgement.parse(Data(bad.utf8)).matches(batch))
    }

    func testAppendBatchSplitsAtDecodedBodyLimitAndKeepsDeterministicIdentity() throws {
        let payload = String(repeating: "x", count: 1_000)
        let records = (1...5000).map {
            PushStoreRecord(rowId: Int64($0),
                            key: ["ts": .integer(Int64($0)), "kind": .string("event")],
                            data: ["payloadJSON": .string(payload)])
        }
        let first = try SelfHostedPushCodec.appendBatch(stream: "event", sourceId: source, deviceId: "dev", start: nil, records: records)
        let second = try SelfHostedPushCodec.appendBatch(stream: "event", sourceId: source, deviceId: "dev", start: nil, records: records)
        XCTAssertLessThanOrEqual(first.body.count, SelfHostedPush.maxBodyBytes)
        XCTAssertLessThan(first.recordCount, records.count)
        XCTAssertEqual(first.batchId, second.batchId)
        XCTAssertEqual(first.body, second.body)
    }

    func testMutableBatchesIncludeEmptyPartAndMultipartMetadata() throws {
        let window = SelfHostedPushWindow(fromDay: "2026-09-01", toDay: "2026-09-14", startTsInclusive: 0, endTsExclusive: 1)
        let empty = try SelfHostedPushCodec.mutableBatches(stream: "journal", sourceId: source, deviceId: "dev", window: window, records: [])
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty[0].recordCount, 0)
        XCTAssertEqual(empty[0].part, 1)
        XCTAssertEqual(empty[0].parts, 1)

        let rows = (0..<20).map { index in
            PushStoreRecord(rowId: nil, key: ["day": .string("2026-09-01"), "question": .string("q\(index)" )], data: ["answeredYes": .bool(true), "notes": .null, "numericValue": .null])
        }
        let batches = try SelfHostedPushCodec.mutableBatches(stream: "journal", sourceId: source, deviceId: "dev", window: window, records: rows)
        XCTAssertEqual(Set(batches.compactMap(\.replacementId)).count, 1)
        XCTAssertEqual(batches.map(\.part), Array(1...batches.count))
    }
}
