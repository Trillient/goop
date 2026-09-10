import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class IntelligenceRRSourceTests: XCTestCase {
    private let canonical = "my-whoop"
    private let active = "new-five"

    private func withPreferences(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
            "profile.heightCm", "profile.waistCm", "profile.hrMaxOverride", "profile.stepTicksPerStep",
            "profile.stepsCalibrationCoefficient", "profile.stepsCalibrationSampleDays",
            "profile.stepsCalibrationConfidence", "profile.stepsCalibrationManual",
            "profile.stepsManualCoefficient", "profile.stepsHasBankedMotion",
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
            "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
            RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
            PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.motionAwareWakeKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(DayCycleMode.midnight.rawValue, forKey: DayCycleMode.storageKey)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
        try await body()
    }

    private func register(_ registry: DeviceRegistryStore, canonicalModel: String) throws {
        try registry.add(PairedDevice(id: canonical, brand: "WHOOP", model: canonicalModel,
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: active, brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .active, addedAt: 2, lastSeenAt: 2))
    }

    private func seedBaseline(_ store: WhoopStore, before day: String) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = try XCTUnwrap(formatter.date(from: day))
        let history = (1...8).map { offset in
            DailyMetric(day: formatter.string(from: date.addingTimeInterval(-Double(offset) * 86_400)),
                totalSleepMin: 480, efficiency: 0.9, deepMin: 90, remMin: 90, lightMin: 300,
                disturbances: 0, restingHr: 60, avgHrv: 32 + Double(offset % 3), recovery: 60,
                strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics(history, deviceId: canonical)
    }

    // A completed night relative to the test's local day, using the established HR-only sleep fixture.
    private func night() -> (day: String, hr: [HRSample], rr: [RRInterval]) {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86_400
        let day = Repository.localDayKey(Date(timeIntervalSince1970: Double(start)))
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(24 * 3_600) {
            let asleep = i >= 16 * 3_600
            let phase = asleep ? i - 16 * 3_600 : i
            let bpm = asleep ? 64 + Int(sin(Double(phase) / 900) * 5)
                             : 74 + Int(sin(Double(phase) / 500) * 11)
            let ts = start - 16 * 3_600 + i
            hr.append(HRSample(ts: ts, bpm: bpm))
            rr.append(RRInterval(ts: ts, rrMs: 900 + (i.isMultiple(of: 2) ? 16 : -16)))
        }
        return (day, hr, rr)
    }

    func testNightlyScoringRejectsLegacyAliasAndRecomputesAfterZeroInsertPromotion() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "WHOOP")
            let input = night()
            try await seedBaseline(store, before: input.day)
            _ = try await store.insert(Streams(hr: input.hr, rr: input.rr), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            repo.adoptActiveDeviceId(active)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            var log: [String] = []
            engine.diagnosticSink = { line, _ in log.append(line) }

            await engine.analyzeRecent(maxDays: 2, force: true)
            let before = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day)
            let first = try XCTUnwrap(before.first)
            XCTAssertGreaterThan(first.totalSleepMin ?? 0, 0, "the fixture must actually score a night")
            XCTAssertNil(first.avgHrv, "legacy alias R-R has unproven units after WHOOP 5 re-pairing")
            XCTAssertNil(first.recovery, "an established baseline cannot score Charge without nightly HRV")
            await repo.refresh()
            XCTAssertNotNil(Whoop5RRGap.message(day: repo.days.first { $0.day == input.day },
                                              excludedDays: repo.legacyRRExcludedDays),
                            "the persisted cause must reach the same helper Today renders")

            // A second repository represents a cold app launch; the explanation must survive it.
            let reopened = Repository(deviceId: active)
            reopened.setStoreForTesting(store)
            await reopened.refresh()
            XCTAssertNotNil(Whoop5RRGap.message(day: first, excludedDays: reopened.legacyRRExcludedDays))

            let tagged = input.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs, srcChannel: .whoop5Historical) }
            let inserted = try await store.insert(Streams(rr: tagged), deviceId: canonical)
            XCTAssertEqual(inserted.rr, 0, "only provenance changes; the existing interval keys are identical")
            log.removeAll()
            await engine.analyzeRecent(maxDays: 2, force: true)
            let after = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day)
            let promoted = try XCTUnwrap(after.first?.avgHrv)
            XCTAssertGreaterThan(promoted, 0, "the same engine must replace its cached R-R-less result")
            XCTAssertNotNil(after.first?.recovery, "Charge returns once valid HRV and its baseline are available")
            await repo.refresh()
            XCTAssertFalse(repo.legacyRRExcludedDays.contains(input.day), "re-sync must clear the persisted flag")
            XCTAssertNil(Whoop5RRGap.message(day: after.first, excludedDays: repo.legacyRRExcludedDays))

            log.removeAll()
            await engine.analyzeRecent(maxDays: 2, force: true)
            let idle = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day)
            XCTAssertEqual(idle.first?.avgHrv, promoted)
            XCTAssertEqual(idle.first?.recovery, after.first?.recovery)
            await repo.refresh()
            XCTAssertFalse(repo.legacyRRExcludedDays.contains(input.day), "a cache hit must not revive the notice")
            XCTAssertTrue(log.contains { $0.contains("dayCache reused=2/2") },
                          "an unchanged pass should reuse both previously scored windows: \(log)")
        }
    }

    func testNightlyScoringKeepsConfirmedWhoop4LegacyIntervalsAfterRePairing() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "4.0")
            let input = night()
            try await seedBaseline(store, before: input.day)
            _ = try await store.insert(Streams(hr: input.hr), deviceId: canonical)
            let repo = Repository(deviceId: active)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let empty = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day).first
            XCTAssertNotNil(empty)
            XCTAssertNil(empty?.avgHrv)
            XCTAssertNil(empty?.recovery)
            await repo.refresh()
            XCTAssertNil(Whoop5RRGap.message(day: empty, excludedDays: repo.legacyRRExcludedDays))
            _ = try await store.insert(Streams(rr: input.rr), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let rows = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day)
            XCTAssertGreaterThan(try XCTUnwrap(rows.first?.avgHrv), 0)
            XCTAssertNotNil(rows.first?.recovery)
            await repo.refresh()
            XCTAssertFalse(repo.legacyRRExcludedDays.contains(input.day), "WHOOP 4 legacy beats remain supported")
            XCTAssertNil(Whoop5RRGap.message(day: rows.first, excludedDays: repo.legacyRRExcludedDays))
        }
    }

    func testLegacyGapDoesNotExplainOrdinaryCalibrationOrAnotherDaysValues() {
        func row(hrv: Double? = nil, recovery: Double? = nil) -> DailyMetric {
            DailyMetric(day: "2026-09-09", totalSleepMin: 480, efficiency: nil,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                avgHrv: hrv, recovery: recovery, strain: nil, exerciseCount: nil)
        }
        let empty = row()
        XCTAssertNil(Whoop5RRGap.message(day: nil, excludedDays: [empty.day]))
        XCTAssertNil(Whoop5RRGap.message(day: empty, excludedDays: []), "no legacy evidence, no warning")
        XCTAssertNil(Whoop5RRGap.message(day: empty, excludedDays: ["2026-09-08"]))
        XCTAssertNil(Whoop5RRGap.message(day: row(recovery: 60), excludedDays: [empty.day]),
                     "an imported Charge value must not be described as missing")
        XCTAssertNil(Whoop5RRGap.message(day: row(hrv: 40), excludedDays: [empty.day]),
                     "valid HRV with an unseeded baseline is ordinary calibration")
    }

    func testLegacyExplanationRefreshesWhenOnlyItsPersistedFlagChanges() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: canonical)
        repo.setStoreForTesting(store)
        let day = Repository.localDayKey(Date())
        await repo.refresh()
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "hrv_rr_legacy_excluded", value: 1)
        ], deviceId: canonical + "-noop")
        await repo.refresh()
        XCTAssertEqual(repo.legacyRRExcludedDays, [day])
        let flaggedSeq = repo.refreshSeq
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "hrv_rr_legacy_excluded", value: 0)
        ], deviceId: canonical + "-noop")
        await repo.refresh()
        XCTAssertTrue(repo.legacyRRExcludedDays.isEmpty)
        XCTAssertGreaterThan(repo.refreshSeq, flaggedSeq, "unchanged daily metrics cannot hide a cleared notice")
    }

    func testSkippedDayClearsItsOldExplanationWithoutTouchingOtherSources() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let now = Int(Date().timeIntervalSince1970)
            let previousDay = Repository.localDayKey(Date().addingTimeInterval(-2 * 86_400))
            let flag = MetricPoint(day: previousDay, key: "hrv_rr_legacy_excluded", value: 1)
            _ = try await store.upsertMetricSeries([flag], deviceId: canonical + "-noop")
            _ = try await store.upsertMetricSeries([flag], deviceId: "other-noop")
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)

            // An entirely empty pass must preserve existing state, just like the scores it accompanies.
            await engine.analyzeRecent(maxDays: 3, force: true)
            let emptyPass = try await store.metricSeries(deviceId: canonical + "-noop",
                key: flag.key, from: previousDay, to: previousDay)
            XCTAssertEqual(emptyPass.first?.value, 1)

            _ = try await store.insert(Streams(hr: (now - 400..<now).map { HRSample(ts: $0, bpm: 60) }),
                deviceId: canonical)
            await engine.analyzeRecent(maxDays: 3, force: true)
            let skipped = try await store.metricSeries(deviceId: canonical + "-noop",
                key: flag.key, from: previousDay, to: previousDay)
            let other = try await store.metricSeries(deviceId: "other-noop",
                key: flag.key, from: previousDay, to: previousDay)
            XCTAssertEqual(skipped.first?.value, 0, "a nonempty replacement clears evidence for a skipped day")
            XCTAssertEqual(other.first?.value, 1, "another computed source retains its history")
        }
    }

    func testNightlySlidingWindowSelectsOneTransportForTheWholeOlderWindow() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "5.0")
            let input = night()
            let standard = input.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs, srcChannel: .whoop5Standard) }
            _ = try await store.insert(Streams(hr: input.hr, rr: standard), deviceId: canonical)
            // Today's read begins 30h before midnight. Only the older day's extension sees history;
            // that single history record must select history for its ENTIRE window, including overlap.
            let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            _ = try await store.insert(Streams(rr: [RRInterval(ts: midnight - 31 * 3_600,
                rrMs: 900, srcChannel: .whoop5Historical)]), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let rows = try await store.dailyMetrics(deviceId: canonical + "-noop", from: input.day, to: input.day)
            let scored = try XCTUnwrap(rows.first)
            XCTAssertGreaterThan(scored.totalSleepMin ?? 0, 0)
            XCTAssertNotNil(scored.restingHr)
            XCTAssertNil(scored.avgHrv, "the history-only window has no beats inside the sleep; cached standard beats must not leak in")
        }
    }

    func testManualNapAndSelfHealGuardAliasBeforeRepositoryAdoptsActiveDevice() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "WHOOP")
            let start = 1_700_000_000
            let duration = 6 * 3_600
            let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
            let grav = (0..<duration).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
            _ = try await store.insert(Streams(hr: hr, gravity: grav), deviceId: canonical)
            // AppModel adopts the new identity asynchronously; the repository still holds my-whoop.
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            await repo.addManualNap(startTs: start, endTs: start + duration)
            let before = try await store.sleepSessions(deviceId: canonical + "-noop",
                from: start, to: start + duration, limit: 10)
            let baseline = try XCTUnwrap(before.first?.stagesJSON)
            let rr = (0..<duration).map { i in
                RRInterval(ts: start + i, rrMs: 1000 + Int(40 * sin(2 * Double.pi * Double(i) / 4)))
            }
            _ = try await store.insert(Streams(rr: rr), deviceId: canonical)
            let guarded = await repo.selfHealEditedStages(from: start, to: start + duration)
            XCTAssertEqual(guarded.first?.stagesJSON, baseline,
                           "self-heal must not use unlabelled alias R-R even before active-ID adoption")
            try register(registry, canonicalModel: "4.0")
            let confirmedFour = await repo.selfHealEditedStages(from: start, to: start + duration)
            XCTAssertNotEqual(confirmedFour.first?.stagesJSON, baseline,
                              "the fixture must expose R-R-dependent staging, retained for confirmed WHOOP 4")
        }
    }
}
