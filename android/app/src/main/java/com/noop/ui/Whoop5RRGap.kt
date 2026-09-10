package com.noop.ui

import com.noop.R
import com.noop.data.DailyMetric

/** The selected day's explanation uses scored evidence and the values actually displayed. */
internal object Whoop5RRGap {
    fun message(day: DailyMetric?, excludedDays: Set<String>): Int? =
        if (day != null && day.avgHrv == null && day.recovery == null && day.day in excludedDays)
            R.string.whoop5_rr_legacy_gap else null
}
