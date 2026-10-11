package com.noop.data

import com.noop.analytics.DismissedSleepGuard
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WhoopRepositorySleepGroupEditTest {
    private val t0 = 1_780_000_000L
    private val device = "my-whoop-noop"

    private fun fragment(start: Long, end: Long) =
        SleepSession(deviceId = device, startTs = start, endTs = end)

    @Test
    fun secondEditTombstonesPreviouslyEditedDetectedFragment() = runBlocking {
        val rows = mutableMapOf<Pair<String, Long>, SleepSession>()
        val tombstones = mutableListOf<DismissedSleep>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "upsertSleepSessions" -> {
                    (args!![0] as List<SleepSession>).forEach { rows[it.deviceId to it.startTs] = it }
                    null
                }
                "insertDismissedSleep" -> {
                    tombstones += args!![0] as List<DismissedSleep>
                    null
                }
                "deleteSleepSession" -> {
                    rows.remove((args!![0] as String) to (args[1] as Long))
                    null
                }
                else -> throw UnsupportedOperationException(method.name)
            }
        } as WhoopDao
        val repository = WhoopRepository(dao)
        val detected = listOf(fragment(t0, t0 + 2 * 3_600), fragment(t0 + 3 * 3_600, t0 + 10 * 3_600))

        repository.updateSleepGroupTimes(detected, t0 + 30 * 60, t0 + 8 * 3_600)
        val firstEdit = rows.values.sortedBy { it.effectiveStartTs }
        assertEquals(2, firstEdit.size)
        assertTrue(firstEdit.all { it.userEdited && it.startTsAdjusted != null })

        repository.updateSleepGroupTimes(firstEdit, t0 + 3 * 3_600, t0 + 7 * 3_600)

        assertEquals(listOf(t0 + 3 * 3_600), rows.values.map { it.startTs })
        val retired = tombstones.single()
        assertEquals(device, retired.deviceId)
        assertEquals(t0, retired.startTs)
        assertEquals(t0 + 2 * 3_600, retired.endTs)
        assertTrue(
            "the next detection of the retired fragment must be filtered",
            DismissedSleepGuard.isSuppressed(
                retired.startTs, retired.endTs,
                tombstones.map { it.startTs to it.endTs },
            ),
        )
    }
}
