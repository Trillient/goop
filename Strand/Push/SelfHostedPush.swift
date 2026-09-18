import CryptoKit
import Foundation
import Network
import Security
import WhoopStore

/// The Apple client for `docs/PUSH_PROTOCOL.md`.
///
/// The endpoint and bearer token are always supplied by the user. The client is inert until enabled,
/// performs capability discovery before reading health data, and advances local progress only after an
/// exact acknowledgement from the receiver.
enum SelfHostedPush {
    static let version = "1.0"
    static let maxRecords = 5_000
    static let maxBodyBytes = 4 * 1024 * 1024
    static let maxAckBytes = 16 * 1024
    static let maxBackupDownloadBytes = 2 * 1024 * 1024 * 1024
    static let maxMutableRecords = 1_000
    static let maxMutableBytes = 2 * 1024 * 1024
    static let appendStreams = ["hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample", "respSample", "gravitySample"]
    static let mutableStreams = ["dailyMetric", "sleepSession", "workout", "journal"]
    static let registry = Set(appendStreams + mutableStreams)
    static let forbiddenRemoteMembers = Set(["command", "commands", "endpoint", "url", "cadence", "schema", "fields"])
    static let backupPath = "/api/backup"
    static let backupListPath = "/api/backup"
    static let backupLatestPath = "/api/backup/latest"

    static func isBackupEndpoint(_ endpoint: SelfHostedPushEndpointPolicy.Valid) -> Bool {
        URL(string: endpoint.url)?.path == backupPath
    }
}

struct SelfHostedPushCursor: Codable, Equatable, Sendable {
    let rowId: Int64
    let keySha256: String
}

struct SelfHostedPushWindow: Codable, Equatable, Sendable {
    let fromDay: String
    let toDay: String
    let startTsInclusive: Int64
    let endTsExclusive: Int64
}

struct SelfHostedPushWindowProgress: Codable, Equatable, Sendable {
    let window: SelfHostedPushWindow
    let batchId: String
    let dayHashes: [String: String]
}

struct SelfHostedPushStoredProgress: Codable, Equatable, Sendable {
    let cursor: SelfHostedPushCursor?
    let window: SelfHostedPushWindowProgress?
}

struct SelfHostedPushBatch: Sendable {
    let stream: String
    let deviceId: String
    let batchId: String
    let body: Data
    let startCursor: SelfHostedPushCursor?
    let endCursor: SelfHostedPushCursor?
    let recordCount: Int
    let replacementId: String?
    let part: Int?
    let parts: Int?
}

struct SelfHostedPushCapabilities: Equatable, Sendable {
    let streams: Set<String>
    let receiverStateId: String

    static func parse(_ data: Data) throws -> SelfHostedPushCapabilities {
        guard data.count <= SelfHostedPush.maxAckBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "capabilities",
              object["protocolVersion"] as? String == SelfHostedPush.version,
              let receiverStateId = object["receiverStateId"] as? String,
              UUID(uuidString: receiverStateId)?.uuidString.lowercased() == receiverStateId,
              let streams = object["streams"] as? [String],
              Set(streams).count == streams.count,
              streams.allSatisfy(SelfHostedPush.registry.contains),
              !object.keys.contains(where: SelfHostedPush.forbiddenRemoteMembers.contains) else {
            throw SelfHostedPushError.invalidCapabilities
        }
        return SelfHostedPushCapabilities(streams: Set(streams), receiverStateId: receiverStateId)
    }
}

struct SelfHostedPushAcknowledgement: Equatable, Sendable {
    let protocolVersion: String
    let batchId: String
    let stream: String
    let deviceId: String
    let endCursor: SelfHostedPushCursor?
    let acceptedRows: Int
    let status: String

    static func parse(_ data: Data) throws -> SelfHostedPushAcknowledgement {
        guard data.count <= SelfHostedPush.maxAckBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let protocolVersion = object["protocolVersion"] as? String,
              let batchId = object["batchId"] as? String,
              let stream = object["stream"] as? String,
              let deviceId = object["deviceId"] as? String,
              let acceptedRows = object["acceptedRows"] as? NSNumber,
              CFGetTypeID(acceptedRows) != CFBooleanGetTypeID(),
              let status = object["status"] as? String,
              !object.keys.contains(where: SelfHostedPush.forbiddenRemoteMembers.contains) else {
            throw SelfHostedPushError.invalidAcknowledgement
        }
        guard let acceptedRows = integer(object["acceptedRows"]), acceptedRows >= 0,
              acceptedRows <= Int64(Int.max) else {
            throw SelfHostedPushError.invalidAcknowledgement
        }
        let endCursor: SelfHostedPushCursor?
        if let value = object["endCursor"] as? [String: Any],
           let rowId = integer(value["rowId"]), rowId > 0,
           let keySha256 = value["keySha256"] as? String,
           keySha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil {
            endCursor = SelfHostedPushCursor(rowId: rowId, keySha256: keySha256)
        } else if object["endCursor"] is NSNull {
            endCursor = nil
        } else {
            throw SelfHostedPushError.invalidAcknowledgement
        }
        return SelfHostedPushAcknowledgement(protocolVersion: protocolVersion, batchId: batchId,
                                              stream: stream, deviceId: deviceId, endCursor: endCursor,
                                              acceptedRows: Int(acceptedRows), status: status)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let integer = number.int64Value
        return number.doubleValue == Double(integer) ? integer : nil
    }

    func matches(_ batch: SelfHostedPushBatch) -> Bool {
        protocolVersion == SelfHostedPush.version && batchId == batch.batchId && stream == batch.stream &&
            deviceId == batch.deviceId && endCursor == batch.endCursor &&
            acceptedRows == batch.recordCount && status == "accepted"
    }
}

enum SelfHostedPushError: Error {
    case invalidEndpoint
    case invalidCapabilities
    case invalidAcknowledgement
    case invalidData
    case oversized
    case transport(SelfHostedPushFailure)
}

struct SelfHostedPushFailure: Equatable, Sendable {
    enum Code: String, Sendable {
        case dnsLookup, tlsCertificate, tlsHandshake, networkTimeout, connectionRefused
        case networkUnreachable, connectionReset, networkIO, httpAuth, httpNotFound, httpTimeout
        case httpTooLarge, httpMediaType, httpProtocolRejected, httpRateLimit, httpServer, httpClient
        case capabilitiesInvalid, acknowledgementInvalid, localData, localDatabase
    }

    let code: Code
    let status: Int?
    let receiverCode: String?

    var retryable: Bool {
        switch code {
        case .dnsLookup, .tlsHandshake, .networkTimeout, .connectionRefused, .networkUnreachable,
             .connectionReset, .networkIO, .httpTimeout, .httpRateLimit, .httpServer, .localDatabase:
            true
        default: false
        }
    }

    static func http(_ status: Int, receiverCode: String?) -> SelfHostedPushFailure {
        let code: Code
        switch status {
        case 401, 403: code = .httpAuth
        case 404: code = .httpNotFound
        case 408: code = .httpTimeout
        case 413: code = .httpTooLarge
        case 415: code = .httpMediaType
        case 400, 409, 422: code = .httpProtocolRejected
        case 429: code = .httpRateLimit
        case 500...599: code = .httpServer
        default: code = .httpClient
        }
        return SelfHostedPushFailure(code: code, status: status, receiverCode: receiverCode)
    }
}

enum SelfHostedPushResult: Equatable, Sendable {
    case accepted(records: Int, batches: Int)
    case noData
    case rejected(SelfHostedPushFailure)
}

enum SelfHostedPushEndpointPolicy {
    enum Problem: Error, Equatable {
        case malformedURL, missingScheme, unsupportedScheme, userInfo, fragment, missingHost
        case invalidPort, cleartextRequiresNumericLocalAddress
    }

    struct Valid: Equatable, Sendable {
        let url: String
        let host: String
    }

    static func validate(_ raw: String) -> Result<Valid, Problem> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value) else { return .failure(.malformedURL) }
        guard let scheme = components.scheme?.lowercased() else { return .failure(.missingScheme) }
        guard scheme == "https" || scheme == "http" else { return .failure(.unsupportedScheme) }
        guard components.user == nil, components.password == nil else { return .failure(.userInfo) }
        guard components.fragment == nil else { return .failure(.fragment) }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.missingHost) }
        guard components.port == nil || (0...65535).contains(components.port!) else { return .failure(.invalidPort) }
        if scheme == "http" && !isNumericLocalAddress(host) { return .failure(.cleartextRequiresNumericLocalAddress) }
        components.scheme = scheme
        components.host = host
        if components.path.isEmpty { components.path = "/" }
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        guard let normalized = components.string else { return .failure(.malformedURL) }
        return .success(Valid(url: normalized, host: host))
    }

    private static func isNumericLocalAddress(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4 {
            let octets = pieces.compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            return octets[0] == 127 || octets[0] == 10 ||
                (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 169 && octets[1] == 254)
        }
        guard let address = IPv6Address(host) else { return false }
        let bytes = Array(address.rawValue)
        guard bytes.count == 16 else { return false }
        return bytes == Array(repeating: 0, count: 15) + [1] ||
            (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) ||
            (bytes[0] & 0xfe) == 0xfc
    }
}

enum SelfHostedPushCodec {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    static func appendBatch(stream: String, sourceId: String, deviceId: String,
                            start: SelfHostedPushCursor?, records: [PushStoreRecord]) throws -> SelfHostedPushBatch {
        guard SelfHostedPush.registry.contains(stream),
              UUID(uuidString: sourceId)?.uuidString.lowercased() == sourceId else { throw SelfHostedPushError.invalidData }
        let candidates = Array(records.prefix(SelfHostedPush.maxRecords))
        guard !candidates.isEmpty else { throw SelfHostedPushError.invalidData }
        guard candidates.dropFirst().enumerated().allSatisfy({ index, row in
            guard let previous = candidates[index].rowId, let current = row.rowId else { return false }
            return current > previous
        }) else { throw SelfHostedPushError.invalidData }

        var selected: [PushStoreRecord] = []
        var lines: [Data] = []
        var rowBytes = 0
        for candidate in candidates {
            let line = try recordLine(stream: stream, record: candidate)
            guard let rowId = candidate.rowId else { throw SelfHostedPushError.invalidData }
            let end = SelfHostedPushCursor(rowId: rowId,
                                           keySha256: try keyFingerprint(stream: stream, deviceId: deviceId, key: candidate.key))
            let headerBytes = try header(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                         start: start, end: end, count: selected.count + 1, batchId: zeroUUID).utf8.count
            if headerBytes + rowBytes + line.count > SelfHostedPush.maxBodyBytes {
                if selected.isEmpty { throw SelfHostedPushError.oversized }
                break
            }
            selected.append(candidate)
            lines.append(line)
            rowBytes += line.count
        }
        guard let last = selected.last, let rowId = last.rowId,
              rowId > (start?.rowId ?? 0) else { throw SelfHostedPushError.invalidData }
        let end = SelfHostedPushCursor(rowId: rowId,
                                       keySha256: try keyFingerprint(stream: stream, deviceId: deviceId, key: last.key))
        let identity = try appendIdentity(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                          start: start, end: end, count: selected.count)
        let batchId = stableId(identity: identity, lines: lines)
        let body = try Data(header(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                   start: start, end: end, count: selected.count, batchId: batchId).utf8)
            + lines.reduce(into: Data()) { $0.append($1) }
        guard body.count <= SelfHostedPush.maxBodyBytes else { throw SelfHostedPushError.oversized }
        return SelfHostedPushBatch(stream: stream, deviceId: deviceId, batchId: batchId, body: body,
                                   startCursor: start, endCursor: end, recordCount: selected.count,
                                   replacementId: nil, part: nil, parts: nil)
    }

    static func mutableBatches(stream: String, sourceId: String, deviceId: String,
                               window: SelfHostedPushWindow, records: [PushStoreRecord]) throws -> [SelfHostedPushBatch] {
        guard SelfHostedPush.registry.contains(stream), UUID(uuidString: sourceId)?.uuidString.lowercased() == sourceId,
               records.count <= SelfHostedPush.maxMutableRecords else { throw SelfHostedPushError.invalidData }
        let lines = try records.map { try recordLine(stream: stream, record: $0) }
        guard lines.reduce(0, { $0 + $1.count }) <= SelfHostedPush.maxMutableBytes else { throw SelfHostedPushError.oversized }
        let keyJSON = try records.map { try canonical(object: try jsonObject($0.key)) }
        guard keyJSON.count == Set(keyJSON).count else { throw SelfHostedPushError.invalidData }
        let wireWindow = try windowObject(stream: stream, window: window)
        let replacementIdentity = try canonical(object: ["deviceId": deviceId, "delivery": "replace_window",
                                                     "protocolVersion": SelfHostedPush.version, "sourceId": sourceId,
                                                     "stream": stream, "window": wireWindow])
        let replacementId = stableId(identity: replacementIdentity, lines: lines)

        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        for line in lines {
            let nextCount = current.count + 1
            let conservativeHeader = try mutableHeader(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                                        window: wireWindow, replacementId: replacementId,
                                                        part: Int.max, parts: Int.max, count: nextCount,
                                                        batchId: zeroUUID)
            if nextCount > SelfHostedPush.maxRecords ||
                conservativeHeader.utf8.count + currentBytes + line.count > SelfHostedPush.maxBodyBytes {
                if current.isEmpty { throw SelfHostedPushError.oversized }
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            let oneHeader = try mutableHeader(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                              window: wireWindow, replacementId: replacementId,
                                              part: Int.max, parts: Int.max, count: 1, batchId: zeroUUID)
            if oneHeader.utf8.count + line.count > SelfHostedPush.maxBodyBytes {
                throw SelfHostedPushError.oversized
            }
            current.append(line)
            currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        let parts = chunks.count
        return try chunks.enumerated().map { index, partLines in
            let part = index + 1
            let identity = try mutableIdentity(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                                window: wireWindow, replacementId: replacementId,
                                                part: part, parts: parts, count: partLines.count)
            let batchId = stableId(identity: try canonical(object: identity), lines: partLines)
            let header = try mutableHeader(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                           window: wireWindow, replacementId: replacementId,
                                           part: part, parts: parts, count: partLines.count, batchId: batchId)
            let body = Data(header.utf8) + partLines.reduce(into: Data()) { $0.append($1) }
            guard partLines.count <= SelfHostedPush.maxRecords,
                  body.count <= SelfHostedPush.maxBodyBytes else { throw SelfHostedPushError.oversized }
            return SelfHostedPushBatch(stream: stream, deviceId: deviceId, batchId: batchId, body: body,
                                       startCursor: nil, endCursor: nil, recordCount: partLines.count,
                                       replacementId: replacementId, part: part, parts: parts)
        }
    }

    static func mutableBatch(stream: String, sourceId: String, deviceId: String,
                             window: SelfHostedPushWindow, records: [PushStoreRecord]) throws -> SelfHostedPushBatch {
        let batches = try mutableBatches(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                          window: window, records: records)
        guard batches.count == 1, let batch = batches.first else { throw SelfHostedPushError.oversized }
        return batch
    }

    static func keyFingerprint(stream: String, deviceId: String, key: [String: PushStoreValue]) throws -> String {
        let keys = keyNames(stream)
        return sha256(Data("\(stream)\n\(deviceId)\n\(try orderedObject(key, keys: keys))".utf8))
    }

    static func dayHash(stream: String, records: [PushStoreRecord]) throws -> String {
        let lines = try records.map { try recordLine(stream: stream, record: $0) }.sorted { $0.lexicographicallyPrecedes($1) }
        var data = Data("noop-push-day-hash\n\(SelfHostedPush.version)\n\(stream)\n".utf8)
        lines.forEach { data.append($0) }
        return sha256(data)
    }

    private static func keyNames(_ stream: String) -> [String] {
        switch stream {
        case "rrInterval": ["ts", "rrMs", "seq"]
        case "event": ["ts", "kind"]
        case "workout": ["startTs", "sport"]
        case "journal": ["day", "question"]
        default: [stream == "dailyMetric" || stream == "sleepSession" ? (stream == "dailyMetric" ? "day" : "startTs") : "ts"]
        }
    }

    private static func dataNames(_ stream: String) -> [String] {
        switch stream {
        case "hrSample": ["bpm"]
        case "rrInterval": ["ord", "srcChannel", "tsSuspect"]
        case "event": ["payloadJSON"]
        case "battery": ["soc", "mv", "charging"]
        case "spo2Sample": ["red", "ir"]
        case "skinTempSample": ["raw", "aux1Raw", "aux2Raw"]
        case "respSample": ["raw"]
        case "gravitySample": ["x", "y", "z", "dynAccel"]
        case "dailyMetric": ["totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances", "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct", "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir"]
        case "sleepSession": ["endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited", "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse"]
        case "workout": ["endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain", "distanceM", "zonesJSON", "notes", "routePolyline", "steps"]
        case "journal": ["answeredYes", "notes", "numericValue"]
        default: []
        }
    }

    private static func recordLine(stream: String, record: PushStoreRecord) throws -> Data {
        let keys = keyNames(stream), data = dataNames(stream)
        guard Set(record.key.keys) == Set(keys), Set(record.data.keys) == Set(data) else { throw SelfHostedPushError.invalidData }
        return try Data(canonical(object: ["data": try jsonObject(record.data), "key": try jsonObject(record.key), "type": "record"]).utf8) + Data([0x0a])
    }

    private static func orderedObject(_ values: [String: PushStoreValue], keys: [String]) throws -> String {
        guard Set(values.keys) == Set(keys), values.count == keys.count else { throw SelfHostedPushError.invalidData }
        return "{" + keys.enumerated().map { index, key in
            (index == 0 ? "" : ",") + quote(key) + ":" + encode(values[key]!)
        }.joined() + "}"
    }

    private static func encode(_ value: PushStoreValue) -> String {
        switch value {
        case .null: "null"
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .string(let value): quote(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    private static func quote(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func jsonObject(_ values: [String: PushStoreValue]) throws -> [String: Any] {
        try values.reduce(into: [String: Any]()) { result, item in
            switch item.value {
            case .null: result[item.key] = NSNull()
            case .integer(let value): result[item.key] = NSNumber(value: value)
            case .real(let value):
                guard value.isFinite else { throw SelfHostedPushError.invalidData }
                result[item.key] = NSNumber(value: value)
            case .string(let value): result[item.key] = value
            case .bool(let value): result[item.key] = value
            }
        }
    }

    private static func canonical(object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func appendIdentity(stream: String, sourceId: String, deviceId: String,
                                       start: SelfHostedPushCursor?, end: SelfHostedPushCursor,
                                       count: Int) throws -> String {
        try canonical(object: ["delivery": "append", "deviceId": deviceId,
                               "endCursor": cursorObject(end), "protocolVersion": SelfHostedPush.version,
                               "recordCount": count, "sourceId": sourceId,
                               "startCursor": start.map(cursorObject) ?? NSNull(), "stream": stream,
                               "type": "batch"])
    }

    private static func header(stream: String, sourceId: String, deviceId: String,
                               start: SelfHostedPushCursor?, end: SelfHostedPushCursor,
                               count: Int, batchId: String) throws -> String {
        try canonical(object: ["batchId": batchId, "delivery": "append", "deviceId": deviceId,
                               "endCursor": cursorObject(end), "protocolVersion": SelfHostedPush.version,
                               "recordCount": count, "sourceId": sourceId,
                               "startCursor": start.map(cursorObject) ?? NSNull(), "stream": stream,
                               "type": "batch"]) + "\n"
    }

    private static func mutableIdentity(stream: String, sourceId: String, deviceId: String,
                                        window: [String: Any], replacementId: String,
                                        part: Int, parts: Int, count: Int) throws -> [String: Any] {
        var full = window
        full["part"] = part
        full["parts"] = parts
        full["replacementId"] = replacementId
        return ["delivery": "replace_window", "deviceId": deviceId,
                "endCursor": NSNull(), "protocolVersion": SelfHostedPush.version,
                "recordCount": count, "sourceId": sourceId, "startCursor": NSNull(),
                "stream": stream, "type": "batch", "window": full]
    }

    private static func mutableHeader(stream: String, sourceId: String, deviceId: String,
                                      window: [String: Any], replacementId: String,
                                      part: Int, parts: Int, count: Int, batchId: String) throws -> String {
        let identity = try mutableIdentity(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                            window: window, replacementId: replacementId,
                                            part: part, parts: parts, count: count)
        var full = identity
        full["batchId"] = batchId
        return try canonical(object: full) + "\n"
    }

    private static func windowObject(stream: String, window: SelfHostedPushWindow) throws -> [String: Any] {
        if stream == "dailyMetric" || stream == "journal" {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let date = formatter.date(from: window.toDay) ?? Date(timeIntervalSince1970: 0)
            let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date) ?? date
            return ["endExclusive": formatter.string(from: end), "selector": "day", "startInclusive": window.fromDay]
        }
        return ["endExclusive": NSNumber(value: window.endTsExclusive), "selector": "startTs", "startInclusive": NSNumber(value: window.startTsInclusive)]
    }

    private static func cursorObject(_ cursor: SelfHostedPushCursor) -> [String: Any] {
        ["keySha256": cursor.keySha256, "rowId": NSNumber(value: cursor.rowId)]
    }

    private static func stableId(identity: String, lines: [Data]) -> String {
        var data = Data(identity.utf8); data.append(0x0a); lines.forEach { data.append($0) }
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class SelfHostedPushSettings {
    enum RunState: String { case idle, running, complete, failed }
    struct Snapshot: Equatable {
        let endpoint: SelfHostedPushEndpointPolicy.Valid?
        let enabled: Bool
        let wifiOnly: Bool
        let hasToken: Bool
        let state: RunState
        let lastSuccessAt: Date?
        let lastError: String?
        let acceptedBatches: Int
        let acceptedRecords: Int
    }

    private let defaults = UserDefaults.standard
    private static let endpointKey = "selfHostedPush.endpoint"
    private static let enabledKey = "selfHostedPush.enabled"
    private static let wifiOnlyKey = "selfHostedPush.wifiOnly"
    private static let sourceIdKey = "selfHostedPush.sourceId"
    private static let stateKey = "selfHostedPush.state"
    private static let successKey = "selfHostedPush.lastSuccessAt"
    private static let errorKey = "selfHostedPush.lastError"
    private static let batchKey = "selfHostedPush.acceptedBatches"
    private static let recordKey = "selfHostedPush.acceptedRecords"
    private static let knownDevicesKey = "selfHostedPush.knownDevices"
    private static let progressPrefix = "selfHostedPush.progress."
    private static let keychainService = "com.noop.self-hosted-push"
    private static let keychainAccount = "bearer-token"

    var endpointText: String { defaults.string(forKey: Self.endpointKey) ?? "" }
    var wifiOnly: Bool { defaults.object(forKey: Self.wifiOnlyKey) == nil ? true : defaults.bool(forKey: Self.wifiOnlyKey) }
    var token: String? { Self.readToken() }
    var sourceId: String {
        if let value = defaults.string(forKey: Self.sourceIdKey),
           let uuid = UUID(uuidString: value) {
            let normalized = uuid.uuidString.lowercased()
            if normalized != value { defaults.set(normalized, forKey: Self.sourceIdKey) }
            return normalized
        }
        let value = UUID().uuidString.lowercased(); defaults.set(value, forKey: Self.sourceIdKey); return value
    }

    var snapshot: Snapshot {
        Snapshot(endpoint: SelfHostedPushEndpointPolicy.validate(endpointText).successValue,
                 enabled: defaults.bool(forKey: Self.enabledKey), wifiOnly: wifiOnly, hasToken: token != nil,
                 state: RunState(rawValue: defaults.string(forKey: Self.stateKey) ?? "idle") ?? .idle,
                 lastSuccessAt: defaults.object(forKey: Self.successKey) as? Date,
                 lastError: defaults.string(forKey: Self.errorKey),
                 acceptedBatches: max(0, defaults.integer(forKey: Self.batchKey)),
                 acceptedRecords: max(0, defaults.integer(forKey: Self.recordKey)))
    }

    func saveEndpoint(_ raw: String) -> Result<SelfHostedPushEndpointPolicy.Valid, SelfHostedPushEndpointPolicy.Problem> {
        let result = SelfHostedPushEndpointPolicy.validate(raw)
        if case .success(let endpoint) = result {
            if endpoint.url != endpointText { clearProgress() }
            defaults.set(endpoint.url, forKey: Self.endpointKey)
        }
        return result
    }

    @discardableResult
    func saveToken(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.clearToken() : Self.saveToken(value)
    }

    func setWifiOnly(_ value: Bool) { defaults.set(value, forKey: Self.wifiOnlyKey) }

    @discardableResult
    func setEnabled(_ value: Bool) -> Bool {
        guard !value || (SelfHostedPushEndpointPolicy.validate(endpointText).successValue != nil && token != nil) else { return false }
        defaults.set(value, forKey: Self.enabledKey)
        if !value { record(state: .idle, error: nil) }
        return true
    }

    func progressNamespace(endpoint: SelfHostedPushEndpointPolicy.Valid, receiverStateId: String) -> String {
        let value = "\(sourceId)\u{0}\(endpoint.url)\u{0}\(SelfHostedPush.version)\u{0}\(receiverStateId)"
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func cursor(stream: String, deviceId: String, namespace: String) -> SelfHostedPushCursor? {
        entry(stream: "append.\(stream).\(hash(deviceId))", namespace: namespace)?.cursor
    }

    func saveCursor(_ cursor: SelfHostedPushCursor, stream: String, deviceId: String, namespace: String) {
        let key = "append.\(stream).\(hash(deviceId))"
        let old = entry(stream: key, namespace: namespace)
        save(SelfHostedPushStoredProgress(cursor: cursor, window: old?.window), stream: key, namespace: namespace)
    }

    func mutableProgress(stream: String, deviceId: String, namespace: String) -> SelfHostedPushWindowProgress? {
        entry(stream: "mutable.\(stream).\(hash(deviceId))", namespace: namespace)?.window
    }

    func saveMutable(_ value: SelfHostedPushWindowProgress, stream: String, deviceId: String, namespace: String) {
        let key = "mutable.\(stream).\(hash(deviceId))"
        let old = entry(stream: key, namespace: namespace)
        save(SelfHostedPushStoredProgress(cursor: old?.cursor, window: value), stream: key, namespace: namespace)
    }

    func record(state: RunState, error: String?) {
        guard defaults.bool(forKey: Self.enabledKey) || state == .idle else { return }
        defaults.set(state.rawValue, forKey: Self.stateKey)
        if let error { defaults.set(String(error.prefix(300)), forKey: Self.errorKey) } else { defaults.removeObject(forKey: Self.errorKey) }
        if state == .complete { defaults.set(Date(), forKey: Self.successKey) }
    }

    func addAccepted(batches: Int, records: Int) {
        defaults.set(defaults.integer(forKey: Self.batchKey) + batches, forKey: Self.batchKey)
        defaults.set(defaults.integer(forKey: Self.recordKey) + records, forKey: Self.recordKey)
    }

    func rememberDeviceIds(_ deviceIds: [String]) {
        let known = Set((defaults.array(forKey: Self.knownDevicesKey) as? [String] ?? []) + deviceIds)
            .filter { !$0.isEmpty }
        defaults.set(known.sorted(), forKey: Self.knownDevicesKey)
    }

    func knownDeviceIds() -> [String] {
        (defaults.array(forKey: Self.knownDevicesKey) as? [String] ?? [])
            .filter { !$0.isEmpty }
            .sorted()
    }

    func clearProgress() {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.progressPrefix) }.forEach(defaults.removeObject(forKey:))
    }

    private func entry(stream: String, namespace: String) -> SelfHostedPushStoredProgress? {
        guard let data = defaults.data(forKey: Self.progressPrefix + namespace),
              let entries = try? JSONDecoder().decode([String: SelfHostedPushStoredProgress].self, from: data) else { return nil }
        return entries[stream]
    }

    private func save(_ value: SelfHostedPushStoredProgress, stream: String, namespace: String) {
        var entries: [String: SelfHostedPushStoredProgress] = [:]
        if let data = defaults.data(forKey: Self.progressPrefix + namespace) { entries = (try? JSONDecoder().decode([String: SelfHostedPushStoredProgress].self, from: data)) ?? [:] }
        entries[stream] = value
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.progressPrefix + namespace) }
    }

    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
    }
    private static func saveToken(_ value: String) -> Bool {
        clearToken(); var query = keychainQuery; query[kSecValueData as String] = Data(value.utf8); query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    private static func readToken() -> String? {
        var query = keychainQuery; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }
    @discardableResult private static func clearToken() -> Bool {
        let status = SecItemDelete(keychainQuery as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound
    }
}

private extension Result where Success == SelfHostedPushEndpointPolicy.Valid, Failure == SelfHostedPushEndpointPolicy.Problem {
    var successValue: Success? { guard case .success(let value) = self else { return nil }; return value }
}

private extension PushStoreValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var intValue: Int64? { if case .integer(let value) = self { return value }; return nil }
}

final class SelfHostedPushTransport {
    private let endpoint: URL
    private let token: String
    private let session: URLSession

    init(endpoint: URL, token: String, wifiOnly: Bool) {
        self.endpoint = endpoint; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false; configuration.allowsCellularAccess = !wifiOnly
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func capabilities() async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SelfHostedPush.version, forHTTPHeaderField: "NOOP-Push-Accept-Version")
        return try await send(request)
    }

    func post(_ batch: SelfHostedPushBatch) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = batch.body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func postBackup(_ body: Data) async throws -> (status: Int, body: Data) {
        let backupURL = endpoint.path == SelfHostedPush.backupPath
            ? endpoint
            : endpoint.appendingPathComponent(SelfHostedPush.backupPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: backupURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func probeBackup() async throws -> (status: Int, body: Data) {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SelfHostedPushTransportError.network
        }
        components.path = SelfHostedPush.backupListPath
        guard let backupURL = components.url else { throw SelfHostedPushTransportError.network }
        var request = URLRequest(url: backupURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func downloadLatestBackup() async throws -> (status: Int, file: URL?, errorBody: Data) {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SelfHostedPushTransportError.network
        }
        components.path = SelfHostedPush.backupLatestPath
        guard let backupURL = components.url else { throw SelfHostedPushTransportError.network }
        var request = URLRequest(url: backupURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw SelfHostedPushTransportError.network }
        if (200...299).contains(http.statusCode) {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("noop-server-download-\(UUID().uuidString).noopbak")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return (http.statusCode, destination, Data())
        }
        let body = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        guard body.count <= SelfHostedPush.maxAckBytes else { throw SelfHostedPushError.oversized }
        return (http.statusCode, nil, body)
    }

    private func send(_ request: URLRequest, maxBytes: Int = SelfHostedPush.maxAckBytes) async throws -> (status: Int, body: Data) {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SelfHostedPushTransportError.network }
        guard body.count <= maxBytes else { throw SelfHostedPushError.oversized }
        return (http.statusCode, body)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SelfHostedPushTransportError: Error { case network }

private enum SelfHostedPushFailureClassifier {
    static func classify(_ error: Error) -> SelfHostedPushFailure {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .init(code: .dnsLookup, status: nil, receiverCode: nil)
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid: return .init(code: .tlsCertificate, status: nil, receiverCode: nil)
        case NSURLErrorSecureConnectionFailed: return .init(code: .tlsHandshake, status: nil, receiverCode: nil)
        case NSURLErrorTimedOut: return .init(code: .networkTimeout, status: nil, receiverCode: nil)
        case NSURLErrorCannotConnectToHost: return .init(code: .connectionRefused, status: nil, receiverCode: nil)
        case NSURLErrorNotConnectedToInternet: return .init(code: .networkUnreachable, status: nil, receiverCode: nil)
        case NSURLErrorNetworkConnectionLost: return .init(code: .connectionReset, status: nil, receiverCode: nil)
        default: return .init(code: .networkIO, status: nil, receiverCode: nil)
        }
    }
}

/// One bounded push pass. A later offload, launch, or explicit action continues a large history from its
/// durable cursor; no network work is placed on the Bluetooth offload call stack.
final class SelfHostedPushRunner {
    private let settings: SelfHostedPushSettings
    private let storeHandle: () async -> WhoopStore?
    private let now: () -> Date
    private let calendar: Calendar

    init(settings: SelfHostedPushSettings, storeHandle: @escaping () async -> WhoopStore?, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .autoupdatingCurrent) {
        self.settings = settings
        self.storeHandle = storeHandle
        self.now = now
        self.calendar = calendar
    }

    convenience init(settings: SelfHostedPushSettings) {
        self.init(settings: settings, storeHandle: { nil })
    }

    func run() async -> SelfHostedPushResult {
        guard settings.snapshot.enabled, let endpoint = SelfHostedPushEndpointPolicy.validate(settings.endpointText).successValue,
              let token = settings.token, let url = URL(string: endpoint.url) else {
            return .rejected(.init(code: .localData, status: nil, receiverCode: nil))
        }
        let transport = SelfHostedPushTransport(endpoint: url, token: token, wifiOnly: settings.wifiOnly)
        if SelfHostedPush.isBackupEndpoint(endpoint) {
            return await uploadCompleteSnapshot(transport: transport)
        }
        let capabilities: SelfHostedPushCapabilities
        do {
            let response = try await transport.capabilities()
            guard (200...299).contains(response.status) else { return .rejected(.http(response.status, receiverCode: receiverCode(response.body))) }
            capabilities = try SelfHostedPushCapabilities.parse(response.body)
        } catch let error as SelfHostedPushError { return .rejected(error.failure) }
        catch { return .rejected(SelfHostedPushFailureClassifier.classify(error)) }

        let namespace = settings.progressNamespace(endpoint: endpoint, receiverStateId: capabilities.receiverStateId)
        guard let store = await storeHandle() else {
            return .rejected(.init(code: .localDatabase, status: nil, receiverCode: nil))
        }
        // The structured PUSH_PROTOCOL streams provide incremental sync, but the canonical server mode
        // also sends a complete database snapshot. That is what preserves tables outside the v1 registry
        // (raw captures, Apple Health/imported rows, metric series, lab/lift data, and future schema).
        do {
            let devices = try await store.pushKnownDeviceIds()
            settings.rememberDeviceIds(devices)
            let allDevices = Array(Set(devices + settings.knownDeviceIds())).filter { !$0.isEmpty }.sorted()
            var acceptedBatches = 0; var acceptedRecords = 0
            for deviceId in allDevices {
                for stream in SelfHostedPush.appendStreams where capabilities.streams.contains(stream) {
                    var cursor = settings.cursor(stream: stream, deviceId: deviceId, namespace: namespace)
                    cursor = try await validCursor(cursor, stream: stream, deviceId: deviceId)
                    while true {
                        let rows = try await store.pushAppendRecords(
                            table: PushStoreAppendTable(rawValue: stream)!, deviceId: deviceId,
                            afterRowId: cursor?.rowId ?? 0, limit: SelfHostedPush.maxRecords + 1)
                        guard !rows.isEmpty else { break }
                        let batch = try SelfHostedPushCodec.appendBatch(
                            stream: stream, sourceId: settings.sourceId, deviceId: deviceId,
                            start: cursor, records: rows)
                        try await deliver(batch, transport: transport, endpoint: endpoint)
                        guard let end = batch.endCursor else { throw SelfHostedPushError.invalidData }
                        settings.saveCursor(end, stream: stream, deviceId: deviceId, namespace: namespace)
                        cursor = end
                        acceptedBatches += 1; acceptedRecords += batch.recordCount
                    }
                }
                for stream in SelfHostedPush.mutableStreams where capabilities.streams.contains(stream) {
                    let result = try await pushMutable(stream: stream, deviceId: deviceId, namespace: namespace,
                                                       transport: transport, endpoint: endpoint)
                    if case .accepted(let records, let batches) = result { acceptedRecords += records; acceptedBatches += batches }
                    if case .rejected = result { return result }
                }
            }
            return acceptedBatches == 0 ? .noData : .accepted(records: acceptedRecords, batches: acceptedBatches)
        } catch let error as SelfHostedPushError { return .rejected(error.failure) }
        catch { return .rejected(.init(code: .localDatabase, status: nil, receiverCode: nil)) }
    }

    private func uploadCompleteSnapshot(transport: SelfHostedPushTransport) async -> SelfHostedPushResult {
        guard let store = await storeHandle() else {
            return .rejected(.init(code: .localDatabase, status: nil, receiverCode: nil))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-self-hosted-\(UUID().uuidString).noopbak")
        let result = await DataBackup.writeBackup(checkpoint: {
            do {
                try await store.checkpointWAL()
                return true
            } catch {
                return false
            }
        }, to: url)
        switch result {
        case .exported, .exportedOversize:
            break
        default:
            try? FileManager.default.removeItem(at: url)
            return .rejected(.init(code: .localDatabase, status: nil, receiverCode: nil))
        }
        do {
            let body = try Data(contentsOf: url)
            let response = try await transport.postBackup(body)
            try? FileManager.default.removeItem(at: url)
            guard (200...299).contains(response.status) else {
                return .rejected(.http(response.status, receiverCode: receiverCode(response.body)))
            }
            return .accepted(records: 0, batches: 1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .rejected(SelfHostedPushFailureClassifier.classify(error))
        }
    }

    private func validCursor(_ cursor: SelfHostedPushCursor?, stream: String, deviceId: String) async throws -> SelfHostedPushCursor? {
        guard let cursor else { return nil }
        guard let store = await storeHandle(),
              let row = try await store.pushAppendRecord(table: PushStoreAppendTable(rawValue: stream)!, deviceId: deviceId, rowId: cursor.rowId),
              try SelfHostedPushCodec.keyFingerprint(stream: stream, deviceId: deviceId, key: row.key) == cursor.keySha256 else { return nil }
        return cursor
    }

    private func pushMutable(stream: String, deviceId: String, namespace: String,
                             transport: SelfHostedPushTransport,
                             endpoint: SelfHostedPushEndpointPolicy.Valid) async throws -> SelfHostedPushResult {
        let fullWindow = currentWindow()
        guard let store = await storeHandle() else { throw SelfHostedPushError.invalidData }
        let rows = try await store.pushMutableRecords(table: PushStoreMutableTable(rawValue: stream)!, deviceId: deviceId,
                                                       fromDay: fullWindow.fromDay, toDay: fullWindow.toDay,
                                                       startTs: fullWindow.startTsInclusive, endTs: fullWindow.endTsExclusive,
                                                       limit: SelfHostedPush.maxMutableRecords + 1)
        guard rows.count <= SelfHostedPush.maxMutableRecords else { throw SelfHostedPushError.oversized }
        let days = (0..<14).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset - 13, to: calendar.startOfDay(for: now())) else { return nil }
            return dayString(date)
        }
        let hashes = try Dictionary(uniqueKeysWithValues: days.map { day in
            (day, try SelfHostedPushCodec.dayHash(stream: stream, records: rows.filter { recordDay(stream: stream, record: $0) == day }))
        })
        guard rows.allSatisfy({ recordDay(stream: stream, record: $0).map(days.contains) == true }) else {
            throw SelfHostedPushError.invalidData
        }
        let previousHashes = settings.mutableProgress(stream: stream, deviceId: deviceId, namespace: namespace)?.dayHashes ?? [:]
        if previousHashes == hashes { return .noData }
        let changedDays = days.filter { previousHashes[$0] != hashes[$0] }
        guard let firstChanged = changedDays.first, let lastChanged = changedDays.last else {
            return .noData
        }
        let window = window(fromDay: firstChanged, toDay: lastChanged)
        let changedRows = rows.filter {
            guard let day = recordDay(stream: stream, record: $0) else { return false }
            return day >= firstChanged && day <= lastChanged
        }
        let batches = try SelfHostedPushCodec.mutableBatches(
            stream: stream, sourceId: settings.sourceId, deviceId: deviceId,
            window: window, records: changedRows)
        for batch in batches { try await deliver(batch, transport: transport, endpoint: endpoint) }
        settings.saveMutable(
            SelfHostedPushWindowProgress(window: fullWindow,
                                         batchId: batches.first?.replacementId ?? batches[0].batchId,
                                         dayHashes: hashes),
            stream: stream, deviceId: deviceId, namespace: namespace)
        return .accepted(records: changedRows.count, batches: batches.count)
    }

    private func deliver(_ batch: SelfHostedPushBatch, transport: SelfHostedPushTransport,
                         endpoint: SelfHostedPushEndpointPolicy.Valid) async throws {
        guard settings.snapshot.enabled,
              SelfHostedPushEndpointPolicy.validate(settings.endpointText).successValue?.url == endpoint.url else {
            throw SelfHostedPushError.invalidData
        }
        let response: (status: Int, body: Data)
        do { response = try await transport.post(batch) }
        catch let error as SelfHostedPushError { throw error }
        catch { throw SelfHostedPushError.transport(SelfHostedPushFailureClassifier.classify(error)) }
        guard (200...299).contains(response.status) else { throw SelfHostedPushError.transport(.http(response.status, receiverCode: receiverCode(response.body))) }
        guard try SelfHostedPushAcknowledgement.parse(response.body).matches(batch) else { throw SelfHostedPushError.invalidAcknowledgement }
    }

    private func currentWindow() -> SelfHostedPushWindow {
        let today = calendar.startOfDay(for: now()); let from = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return SelfHostedPushWindow(fromDay: dayString(from), toDay: dayString(today), startTsInclusive: Int64(from.timeIntervalSince1970), endTsExclusive: Int64(end.timeIntervalSince1970))
    }

    private func window(fromDay: String, toDay: String) -> SelfHostedPushWindow {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let from = formatter.date(from: fromDay) ?? calendar.startOfDay(for: now())
        let to = formatter.date(from: toDay) ?? from
        let end = calendar.date(byAdding: .day, value: 1, to: to) ?? to
        return SelfHostedPushWindow(fromDay: fromDay, toDay: toDay,
                                    startTsInclusive: Int64(from.timeIntervalSince1970),
                                    endTsExclusive: Int64(end.timeIntervalSince1970))
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func recordDay(stream: String, record: PushStoreRecord) -> String? {
        if stream == "dailyMetric" || stream == "journal" { return record.key["day"]?.stringValue }
        guard let seconds = record.key["startTs"]?.intValue else { return nil }
        return dayString(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func receiverCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "error",
              let code = object["code"] as? String, code.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }

    func restoreLatestBackup() async -> SelfHostedPushRestoreResult {
        guard let endpoint = settings.snapshot.endpoint,
              SelfHostedPush.isBackupEndpoint(endpoint),
              let token = settings.token,
              let url = URL(string: endpoint.url) else { return .unavailable }
        do {
            let transport = SelfHostedPushTransport(endpoint: url, token: token, wifiOnly: settings.wifiOnly)
            let response = try await transport.downloadLatestBackup()
            guard (200...299).contains(response.status) else {
                return .failed(SelfHostedPushFailure.http(response.status, receiverCode: receiverCode(response.errorBody)))
            }
            guard let destination = response.file else { return .unavailable }
            defer { try? FileManager.default.removeItem(at: destination) }
            let result = DataBackup.restore(from: destination)
            switch result {
            case .imported(let sidecar): return .restored(sidecar: sidecar)
            case .restoreTooLarge(let name, let limit): return .tooLarge(name: name, limit: limit)
            case .failure(let message): return .failed(SelfHostedPushFailure(code: .localData, status: nil, receiverCode: message))
            default: return .unavailable
            }
        } catch let failure as SelfHostedPushError {
            return .failed(failure.failure)
        } catch {
            return .failed(SelfHostedPushFailure(code: .networkIO, status: nil, receiverCode: nil))
        }
    }
}

enum SelfHostedPushRestoreResult: Sendable {
    case restored(sidecar: URL)
    case tooLarge(name: String, limit: Int64)
    case unavailable
    case failed(SelfHostedPushFailure)
}

extension SelfHostedPushError {
    var failure: SelfHostedPushFailure {
        switch self {
        case .invalidEndpoint, .invalidData, .oversized: .init(code: .localData, status: nil, receiverCode: nil)
        case .invalidCapabilities: .init(code: .capabilitiesInvalid, status: nil, receiverCode: nil)
        case .invalidAcknowledgement: .init(code: .acknowledgementInvalid, status: nil, receiverCode: nil)
        case .transport(let failure): failure
        }
    }
}
