import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

@MainActor
final class DayCycleRecoveryTests: XCTestCase {
    private enum ReadFailure: Error { case injected }

    func testApplyingCycleStepsPreservesUnrelatedDailyColumns() {
        let daily = DailyMetric(
            day: "2026-09-04", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 10, activeKcalEst: nil, skinTempC: 34.2, sleepHrOnly: true)
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: [daily.day: 42], strainByWakeDay: [daily.day: 61],
            caloriesByWakeDay: [daily.day: 1_840], workoutCountByWakeDay: [daily.day: 2],
            onsetByWakeDay: [:], firstWakeDay: daily.day,
            markerUpdate: .preserve)

        let updated = DayCycleIntelligenceIntegration.applying(result, to: daily)

        XCTAssertEqual(updated.steps, 42)
        XCTAssertEqual(updated.strain, 61)
        XCTAssertEqual(updated.activeKcalEst, 1_840)
        XCTAssertEqual(updated.exerciseCount, 2)
        XCTAssertEqual(updated.skinTempC, 34.2)
        XCTAssertEqual(updated.sleepHrOnly, true)
    }

    func testBoundaryRecoveryPropagatesSessionReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
            // Expected: callers can distinguish an unread namespace from an authoritative empty one.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBoundaryRecoveryPropagatesMarkerReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in [] },
            markers: { _, _, _ in throw ReadFailure.injected })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testComputePreservesMarkersWhenRecoveryCannotBeRead() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        let result = await DayCycleIntelligenceIntegration.compute(
            nights: [], editedRows: [], store: store,
            candidates: [(owner: "strap", priority: 0)],
            physiologyOwners: ["strap"], workouts: [],
            windowStart: 1_700_000_000, now: 1_700_086_400, offsetSec: 0,
            habitualMidsleepSec: nil, ticksPerStep: 1, mode: .sleepOnset,
            cache: DayCycleIntelligenceIntegration.Cache(), profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards, recoveryReader: reader)

        guard case .preserve = result.markerUpdate else {
            return XCTFail("an unread marker namespace must never become an authoritative replacement")
        }
        XCTAssertTrue(result.stepsByWakeDay.isEmpty)
        XCTAssertTrue(result.onsetByWakeDay.isEmpty)
    }

    func testPass2SkinTempDeviationBeforeRecoveryScoring() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-09-09"
        let nightlySkinTempC = 34.8
        let skinTempBaseline = Baselines.Baseline(
            baseline: 34.5, spread: 0.4, nValid: 14, nightsSinceUpdate: 0,
            status: .trusted)
        let hrvBaseline = Baselines.Baseline(
            baseline: 50.0, spread: 6.0, nValid: 14, nightsSinceUpdate: 0,
            status: .trusted)

        let baselines = Baselines(
            hrv: hrvBaseline, rhr: nil, resp: nil, skinTemp: skinTempBaseline, strain: nil, vo2max: nil)
        let skinTempDevC = nightlySkinTempC - skinTempBaseline.baseline
        let hrv = 48.0
        let rhr = 58.0

        let scoreWithSkinDev = RecoveryScorer.recovery(
            hrv: hrv, rhr: rhr, resp: nil,
            hrvBaseline: RecoveryScorer.DriverBaseline(hrvBaseline),
            rhrBaseline: nil, respBaseline: nil,
            sleepPerf: 0.85, skinTempDev: skinTempDevC)

        let scoreWithoutSkinDev = RecoveryScorer.recovery(
            hrv: hrv, rhr: rhr, resp: nil,
            hrvBaseline: RecoveryScorer.DriverBaseline(hrvBaseline),
            rhrBaseline: nil, respBaseline: nil,
            sleepPerf: 0.85, skinTempDev: nil)

        XCTAssertNotNil(scoreWithSkinDev)
        XCTAssertNotNil(scoreWithoutSkinDev)
        XCTAssertNotEqual(scoreWithSkinDev, scoreWithoutSkinDev,
                          "Charge with non-nil skinTempDev must differ from nil-deviation when deviation is non-trivial")

        try await store.writeSync { db in
            try db.execute(sql: """
                INSERT INTO daily_metric (day, avg_hrv, resting_hr, total_sleep_min, efficiency)
                VALUES (?, ?, ?, 420, 0.85)
                """, arguments: [day, hrv, rhr])
        }

        let nights = [IntelligenceEngine.ScoredNight(
            daily: DailyMetric(
                day: day, totalSleepMin: 420, efficiency: 0.85, deepMin: nil, remMin: nil,
                lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: nil,
                skinTempDevC: nil, respRateBpm: nil, steps: nil, activeKcalEst: nil,
                skinTempC: nil, sleepHrOnly: false),
            cachedSleep: [],
            nightlySkin: nightlySkinTempC)]

        let computed = await IntelligenceEngine.score(
            scoredNights: nights, editedRows: [], baselines: baselines,
            importedWhoopDays: [], appleHealthDays: [], tzOffset: 0, nowSeconds: 0,
            resolvedScoreOwnerByDay: [:], candidatePriorities: [], habitualMidsleepSec: nil,
            store: store, stepTicksPerStep: 1, physiologicalStepsResult: nil,
            stepsTraceActive: false, dayCycleMode: .sleepOnset, profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards, diagnosticSink: nil)

        XCTAssertEqual(computed.count, 1)
        let result = computed.first!
        XCTAssertEqual(result.recovery, scoreWithSkinDev,
                       "Pass-2 Charge must match RecoveryScorer called WITH skinTempDev, not nil")
        XCTAssertNotNil(result.skinTempRel)
    }
}
