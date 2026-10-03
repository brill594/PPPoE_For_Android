package com.brill.pppoe_controller.logging

import java.io.ByteArrayOutputStream

/** Byte offsets and partial UTF-8 lines must survive separate root reads. */
class LogCursor(private val maxRead: Int = 65536, private val maxLine: Int = 8192) {
    var offset = 0L
        private set
    private var identity: String? = null
    private val pending = ByteArrayOutputStream()
    private var discardPartial = false

    data class Window(val start: Long, val count: Int, val skipped: Long, val reset: Boolean)

    fun seekToEnd(id: String, size: Long, endsWithNewline: Boolean) {
        identity = id
        offset = size
        pending.reset()
        discardPartial = size > 0 && !endsWithNewline
    }

    fun window(id: String, size: Long): Window {
        require(size >= 0)
        val reset = identity != null && (identity != id || size < offset)
        if (identity != id || size < offset) {
            offset = 0
            pending.reset()
            discardPartial = false
        }
        identity = id
        val skipped = maxOf(0, size - offset - maxRead)
        if (skipped > 0) {
            offset += skipped
            pending.reset()
            discardPartial = true
        }
        return Window(offset, minOf(size - offset, maxRead.toLong()).toInt(), skipped, reset)
    }

    fun consume(bytes: ByteArray): List<String> {
        offset += bytes.size
        val lines = mutableListOf<String>()
        for (byte in bytes) {
            if (byte == '\n'.code.toByte()) {
                if (!discardPartial && pending.size() > 0) {
                    lines += pending.toString("UTF-8").trimEnd('\r')
                }
                pending.reset()
                discardPartial = false
            } else if (!discardPartial) {
                if (pending.size() >= maxLine) {
                    lines += "[WARN] [app] event=logs_truncated reason=oversized_line"
                    pending.reset()
                    discardPartial = true
                } else {
                    pending.write(byte.toInt())
                }
            }
        }
        return lines
    }
}
