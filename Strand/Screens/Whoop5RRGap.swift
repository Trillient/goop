import Foundation
import SwiftUI
import StrandDesign
import WhoopStore

/// The selected day's explanation, derived from the scored evidence and the values the UI displays.
enum Whoop5RRGap {
    static func message(day: DailyMetric?, excludedDays: Set<String>) -> String? {
        guard let day, day.avgHrv == nil, day.recovery == nil,
              excludedDays.contains(day.day) else { return nil }
        return String(localized: "Earlier WHOOP 5 beats cannot be scored for HRV or Charge. Re-sync your strap to recover available history.")
    }
}

/// Shared by both Apple Today layouts so the explanation has the same visible and accessible copy.
struct Whoop5RRGapNotice: View {
    let message: String

    var body: some View {
        NoopCard(padding: NoopMetrics.space3, tint: StrandPalette.chargeColor) {
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("whoop5RRGapNotice")
    }
}
