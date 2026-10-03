package com.brill.pppoe_controller.logging

import java.time.Instant
import java.util.UUID

class AttemptLog(
    val startedAt: Long = System.currentTimeMillis(),
    val id: String = UUID.randomUUID().toString(),
    private val maxLines: Int = 1000,
    private val maxChars: Int = 262144
) {
    private val lines = ArrayDeque<String>()
    private var chars = 0
    private var dropped = 0

    fun add(line: String) {
        val safe = LogSanitizer.sanitize(line)
        lines.addLast(safe)
        chars += safe.length
        while (lines.size > maxLines || chars > maxChars) {
            chars -= lines.removeFirst().length
            dropped++
        }
    }

    fun content(): String {
        val notice = if (dropped > 0) {
            "${Instant.ofEpochMilli(startedAt)} [WARN] [app] event=logs_truncated attempt=$id dropped_lines=$dropped\n"
        } else ""
        return notice + lines.joinToString("\n")
    }
}
