package com.brill.pppoe_controller

import com.brill.pppoe_controller.logging.AttemptLog
import com.brill.pppoe_controller.logging.LogCursor
import com.brill.pppoe_controller.logging.LogSanitizer
import com.brill.pppoe_controller.logging.RootLogStream
import java.util.Base64
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LogCaptureTest {
    @Test
    fun byteChunksDoNotInventLinesOrCorruptUtf8Evidence() {
        val cursor = LogCursor()
        val bytes = "认证失败\nPAP authentication failed\n".toByteArray()
        cursor.window("file", bytes.size.toLong())
        assertTrue(cursor.consume(bytes.copyOfRange(0, 2)).isEmpty())
        assertEquals(listOf("认证失败", "PAP authentication failed"), cursor.consume(bytes.copyOfRange(2, bytes.size)))
        assertEquals(bytes.size.toLong(), cursor.offset)
    }

    @Test
    fun newAttemptExcludesEarlierLinesAndPartialOldEvidence() {
        val cursor = LogCursor()
        cursor.seekToEnd("file", 20, false)
        assertEquals(listOf("new error"), cursor.consume("old suffix\nnew error\n".toByteArray()))
        cursor.seekToEnd("file", 100, true)
        assertEquals(listOf("first new line"), cursor.consume("first new line\n".toByteArray()))
    }

    @Test
    fun rotationAndTruncationDiscardUnfinishedOldLines() {
        val cursor = LogCursor()
        cursor.window("old", 9)
        cursor.consume("old error".toByteArray())
        assertTrue(cursor.window("new", 20).reset)
        assertEquals(listOf("recovered"), cursor.consume("recovered\n".toByteArray()))
        assertTrue(cursor.window("new", 0).reset)
        assertEquals(0, cursor.offset)
    }

    @Test
    fun overrunIsReportedAndIncompleteFirstLineIsDiscarded() {
        val cursor = LogCursor(maxRead = 8)
        val window = cursor.window("file", 20)
        assertEquals(12, window.skipped)
        assertEquals(8, window.count)
        assertEquals(listOf("ok"), cursor.consume("tail\nok\n".toByteArray()))
        val limited = LogCursor(maxLine = 4)
        assertTrue(limited.consume("password=verylong\n".toByteArray()).single().contains("event=logs_truncated"))
    }

    @Test
    fun storedLogsNeverExposeCredentialWritesOrAuthPayloads() {
        val samples = listOf(
            "+ PASSWORD=secret with spaces",
            "2026-10-04T00:00:00Z password=secret with spaces",
            "https://alice:secret@example.org",
            "password \"secret value\"",
            "Executing: printf '%s' 'secret' > /data/local/tmp/pppoe_pass",
            "rcvd [PAP AuthReq id=1 user=alice password=secret]",
            "sent [CHAP Response id=1 <abcd> name=alice]"
        )
        for (line in samples) {
            val safe = LogSanitizer.sanitize(line)
            assertFalse(safe, safe.contains("secret"))
            assertFalse(safe, safe.contains("alice"))
            assertFalse(safe, safe.contains("with spaces"))
        }
        assertEquals("PAP authentication failed", LogSanitizer.sanitize("PAP authentication failed"))
    }

    @Test
    fun boundedHistoryMakesEvidenceLossVisible() {
        val attempt = AttemptLog(startedAt = 1, id = "test", maxLines = 2)
        attempt.add("old")
        attempt.add("password=secret")
        attempt.add("PAP authentication failed")
        val content = attempt.content()
        assertTrue(content.contains("dropped_lines=1"))
        assertFalse(content.contains("secret"))
        assertTrue(content.contains("PAP authentication failed"))
    }
    @Test
    fun attemptCaptureSurvivesUnsubscribingAndExcludesOldLogs() = runBlocking {
        val content = AtomicReference("old failure\n")
        val captured = mutableListOf<String>()
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val stream = RootLogStream(scope, onLine = { captured += it }, read = { command ->
            val text = content.get()
            val bytes = text.toByteArray()
            when {
                command.startsWith("if ") -> "1 ${bytes.size}\n${text.substringBefore('\n')}"
                command.startsWith("tail -c 1 ") -> Base64.getEncoder().encodeToString(bytes.takeLast(1).toByteArray())
                else -> {
                    val range = Regex("tail -c \\+(\\d+).*head -c (\\d+)").find(command)!!
                    val start = range.groupValues[1].toInt() - 1
                    val count = range.groupValues[2].toInt()
                    Base64.getEncoder().encodeToString(bytes.drop(start).take(count).toByteArray())
                }
            }
        })
        try {
            stream.beginCapture()
            stream.onCancel(null)
            content.set("old failure\nPAP authentication failed\n")
            stream.drain()
            assertTrue(captured.any { it.contains("PAP authentication failed") })
            assertFalse(captured.any { it.contains("old failure") })
        } finally {
            stream.close()
            scope.cancel()
        }
    }

}
