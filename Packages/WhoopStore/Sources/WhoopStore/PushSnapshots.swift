import Foundation
import GRDB

/// The fixed database projections used by the self-hosted push protocol.
///
/// Keep this list explicit. A new SQLite column must not become network-visible without a protocol
/// registry update and a deliberate review.
public enum PushStoreAppendTable: String, CaseIterable, Sendable {
    case hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample, gravitySample
}

public enum PushStoreMutableTable: String, CaseIterable, Sendable {
    case dailyMetric, sleepSession, workout, journal
}

public enum PushStoreValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case string(String)
    case bool(Bool)
}

public struct PushStoreRecord: Equatable, Sendable {
    public let rowId: Int64?
    public let key: [String: PushStoreValue]
    public let data: [String: PushStoreValue]

    public init(rowId: Int64?, key: [String: PushStoreValue], data: [String: PushStoreValue]) {
        self.rowId = rowId
        self.key = key
        self.data = data
    }
}

extension WhoopStore {
    /// Discovers device namespaces without exposing device names or MAC addresses.
    public func pushKnownDeviceIds() async throws -> [String] {
        try syncRead { db in
            let tables = PushStoreAppendTable.allCases.map(\.rawValue) + PushStoreMutableTable.allCases.map(\.rawValue)
            var sql = "SELECT id FROM device WHERE id <> ''"
            for table in tables { sql += " UNION SELECT deviceId FROM \(table) WHERE deviceId <> ''" }
            sql += " ORDER BY id"
            return try String.fetchAll(db, sql: sql)
        }
    }

    /// Returns a bounded append page ordered by SQLite rowid. Rowid is cursor metadata, never wire data.
    public func pushAppendRecords(table: PushStoreAppendTable, deviceId: String,
                                  afterRowId: Int64, limit: Int) async throws -> [PushStoreRecord] {
        precondition(limit > 0)
        return try syncRead { db in
            switch table {
            case .hrSample:
                let sql = "SELECT rowid AS _id, ts, bpm FROM hrSample WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "hrSample", columns: ["ts", "bpm"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["bpm": integer(r, "bpm")])
                }
            case .rrInterval:
                let sql = "SELECT rowid AS _id, ts, rrMs, seq, ord, srcChannel, tsSuspect FROM rrInterval WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "rrInterval", columns: ["ts", "rrMs", "seq", "ord", "srcChannel", "tsSuspect"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts"), "rrMs": integer(r, "rrMs"), "seq": integer(r, "seq")], data: ["ord": integer(r, "ord"), "srcChannel": integer(r, "srcChannel"), "tsSuspect": integer(r, "tsSuspect")])
                }
            case .event:
                let sql = "SELECT rowid AS _id, ts, kind, payloadJSON FROM event WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "event", columns: ["ts", "kind", "payloadJSON"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts"), "kind": string(r, "kind")], data: ["payloadJSON": string(r, "payloadJSON")])
                }
            case .battery:
                let sql = "SELECT rowid AS _id, ts, soc, mv, charging FROM battery WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "battery", columns: ["ts", "soc", "mv", "charging"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["soc": real(r, "soc"), "mv": integer(r, "mv"), "charging": bool(r, "charging")])
                }
            case .spo2Sample:
                let sql = "SELECT rowid AS _id, ts, red, ir FROM spo2Sample WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "spo2Sample", columns: ["ts", "red", "ir"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["red": integer(r, "red"), "ir": integer(r, "ir")])
                }
            case .skinTempSample:
                let sql = "SELECT rowid AS _id, ts, raw, aux1Raw, aux2Raw FROM skinTempSample WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "skinTempSample", columns: ["ts", "raw", "aux1Raw", "aux2Raw"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["raw": integer(r, "raw"), "aux1Raw": integer(r, "aux1Raw"), "aux2Raw": integer(r, "aux2Raw")])
                }
            case .respSample:
                let sql = "SELECT rowid AS _id, ts, raw FROM respSample WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "respSample", columns: ["ts", "raw"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["raw": integer(r, "raw")])
                }
            case .gravitySample:
                let sql = "SELECT rowid AS _id, ts, x, y, z, dynAccel FROM gravitySample WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?"
                try preflight(db, table: "gravitySample", columns: ["ts", "x", "y", "z", "dynAccel"], predicate: "deviceId = ? AND rowid > ?", order: "rowid", arguments: [deviceId, afterRowId, limit])
                return try fetch(db, sql, [deviceId, afterRowId, limit]) { r in
                    record(r, id: "_id", key: ["ts": integer(r, "ts")], data: ["x": real(r, "x"), "y": real(r, "y"), "z": real(r, "z"), "dynAccel": real(r, "dynAccel")])
                }
            }
        }
    }

    public func pushAppendRecord(table: PushStoreAppendTable, deviceId: String,
                                 rowId: Int64) async throws -> PushStoreRecord? {
        try await pushAppendRecords(table: table, deviceId: deviceId, afterRowId: rowId - 1, limit: 1)
            .first(where: { $0.rowId == rowId })
    }

    /// Returns one bounded mutable window. The caller decides the local timezone and horizon.
    public func pushMutableRecords(table: PushStoreMutableTable, deviceId: String,
                                   fromDay: String, toDay: String, startTs: Int64,
                                   endTs: Int64, limit: Int) async throws -> [PushStoreRecord] {
        precondition(limit > 0)
        return try syncRead { db in
            switch table {
            case .dailyMetric:
                try preflight(db, table: "dailyMetric", columns: ["day", "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances", "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct", "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir"], predicate: "deviceId = ? AND day >= ? AND day <= ?", order: "day", arguments: [deviceId, fromDay, toDay, limit])
                return try fetch(db, "SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances, restingHr, avgHrv, recovery, strain, exerciseCount, spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst, spo2Red, spo2Ir FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day LIMIT ?", [deviceId, fromDay, toDay, limit]) { r in
                    record(r, key: ["day": string(r, "day")], data: ["totalSleepMin": real(r, "totalSleepMin"), "efficiency": real(r, "efficiency"), "deepMin": real(r, "deepMin"), "remMin": real(r, "remMin"), "lightMin": real(r, "lightMin"), "disturbances": integer(r, "disturbances"), "restingHr": integer(r, "restingHr"), "avgHrv": real(r, "avgHrv"), "recovery": real(r, "recovery"), "strain": real(r, "strain"), "exerciseCount": integer(r, "exerciseCount"), "spo2Pct": real(r, "spo2Pct"), "skinTempDevC": real(r, "skinTempDevC"), "respRateBpm": real(r, "respRateBpm"), "steps": integer(r, "steps"), "activeKcalEst": real(r, "activeKcalEst"), "spo2Red": integer(r, "spo2Red"), "spo2Ir": integer(r, "spo2Ir")])
                }
            case .sleepSession:
                try preflight(db, table: "sleepSession", columns: ["startTs", "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited", "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse"], predicate: "deviceId = ? AND startTs >= ? AND startTs < ?", order: "startTs", arguments: [deviceId, startTs, endTs, limit])
                return try fetch(db, "SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited, startTsAdjusted, motionJSON, sleepStateJSON, stagingSparse FROM sleepSession WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs LIMIT ?", [deviceId, startTs, endTs, limit]) { r in
                    record(r, key: ["startTs": integer(r, "startTs")], data: ["endTs": integer(r, "endTs"), "efficiency": real(r, "efficiency"), "restingHr": integer(r, "restingHr"), "avgHrv": real(r, "avgHrv"), "stagesJSON": string(r, "stagesJSON"), "userEdited": bool(r, "userEdited"), "startTsAdjusted": integer(r, "startTsAdjusted"), "motionJSON": string(r, "motionJSON"), "sleepStateJSON": string(r, "sleepStateJSON"), "stagingSparse": bool(r, "stagingSparse")])
                }
            case .workout:
                try preflight(db, table: "workout", columns: ["startTs", "endTs", "sport", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain", "distanceM", "zonesJSON", "notes", "steps"], predicate: "deviceId = ? AND startTs >= ? AND startTs < ?", order: "startTs, sport", arguments: [deviceId, startTs, endTs, limit])
                return try fetch(db, "SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr, strain, distanceM, zonesJSON, notes, steps FROM workout WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs, sport LIMIT ?", [deviceId, startTs, endTs, limit]) { r in
                    record(r, key: ["startTs": integer(r, "startTs"), "sport": string(r, "sport")], data: ["endTs": integer(r, "endTs"), "source": string(r, "source"), "durationS": real(r, "durationS"), "energyKcal": real(r, "energyKcal"), "avgHr": integer(r, "avgHr"), "maxHr": integer(r, "maxHr"), "strain": real(r, "strain"), "distanceM": real(r, "distanceM"), "zonesJSON": string(r, "zonesJSON"), "notes": string(r, "notes"), "routePolyline": .null, "steps": integer(r, "steps")])
                }
            case .journal:
                try preflight(db, table: "journal", columns: ["day", "question", "answeredYes", "notes", "numericValue"], predicate: "deviceId = ? AND day >= ? AND day <= ?", order: "day, question", arguments: [deviceId, fromDay, toDay, limit])
                return try fetch(db, "SELECT day, question, answeredYes, notes, numericValue FROM journal WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day, question LIMIT ?", [deviceId, fromDay, toDay, limit]) { r in
                    record(r, key: ["day": string(r, "day"), "question": string(r, "question")], data: ["answeredYes": bool(r, "answeredYes"), "notes": string(r, "notes"), "numericValue": real(r, "numericValue")])
                }
            }
        }
    }

    private func fetch<T>(_ db: Database, _ sql: String, _ args: [DatabaseValueConvertible?], _ map: (Row) -> T) throws -> [T] {
        try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(map)
    }

    /// Reject an oversized exact selection before GRDB materializes its unrestricted text columns.
    /// The estimate deliberately overcharges text for JSON escaping and includes fixed row/object
    /// overhead, matching the Android preflight rather than relying on the final encoded body limit.
    private func preflight(_ db: Database, table: String, columns: [String], predicate: String,
                           order: String, arguments: [DatabaseValueConvertible?]) throws {
        let estimate = columns.map { column in
            "CASE WHEN \(column) IS NULL THEN 4 WHEN typeof(\(column)) = 'text' THEN length(CAST(\(column) AS BLOB)) * 6 + 2 WHEN typeof(\(column)) = 'blob' THEN \(PushSnapshotPreflight.maxEstimate + 1) ELSE 32 END"
        }.joined(separator: " + ")
        let sql = "SELECT COALESCE(SUM(\(PushSnapshotPreflight.fixedRowOverhead) + \(estimate)), 0) FROM (SELECT \(columns.joined(separator: ", ")) FROM \(table) WHERE \(predicate) ORDER BY \(order) LIMIT ?)"
        let value = try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        if value > PushSnapshotPreflight.maxEstimate { throw WhoopStorePushError.snapshotTooLarge }
    }
}

private enum PushSnapshotPreflight {
    static let fixedRowOverhead: Int64 = 4 * 1024
    static let maxEstimate: Int64 = 48 * 1024 * 1024
}

public enum WhoopStorePushError: Error, Equatable {
    case snapshotTooLarge
}

private func record(_ row: Row, id: String? = nil, key: [String: PushStoreValue], data: [String: PushStoreValue]) -> PushStoreRecord {
    PushStoreRecord(rowId: id.flatMap { row[$0] }, key: key, data: data)
}

private func integer(_ row: Row, _ column: String) -> PushStoreValue {
    (row[column] as Int64?).map(PushStoreValue.integer) ?? .null
}

private func real(_ row: Row, _ column: String) -> PushStoreValue {
    (row[column] as Double?).map(PushStoreValue.real) ?? .null
}

private func string(_ row: Row, _ column: String) -> PushStoreValue {
    (row[column] as String?).map(PushStoreValue.string) ?? .null
}

private func bool(_ row: Row, _ column: String) -> PushStoreValue {
    if let value = row[column] as Int? { return .bool(value != 0) }
    return .null
}
