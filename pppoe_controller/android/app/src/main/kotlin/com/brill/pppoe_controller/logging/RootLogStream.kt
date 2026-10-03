package com.brill.pppoe_controller.logging

import com.brill.pppoe_controller.su.RootShell
import io.flutter.plugin.common.EventChannel
import java.time.Instant
import java.util.Base64
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class RootLogStream(
    private val scope: CoroutineScope,
    private val onLine: (String) -> Unit,
    private val read: (String) -> String = RootShell::read
) : EventChannel.StreamHandler {
    private val path = "/data/local/tmp/pppoe.log"
    private val cursor = LogCursor()
    private val readMutex = Mutex()
    private var job: Job? = null
    private var sink: EventChannel.EventSink? = null
    private var capturing = false
    private var lastError: String? = null

    private data class Snapshot(val identity: String, val size: Long)

    private suspend fun snapshot(): Snapshot = withContext(Dispatchers.IO) {
        // The first line changes after copytruncate/restart even if the inode is reused.
        val value = read("if [ -f $path ]; then stat -c '%i %s' $path && head -c 512 $path | head -n 1; else echo 'missing 0'; fi")
        val header = value.substringBefore('\n').trim().split(Regex("\\s+"))
        Snapshot(header[0] + ":" + value.substringAfter('\n', ""), header[1].toLong())
    }

    fun event(level: String, event: String, details: String = ""): String {
        val line = "${Instant.now()} [$level] [app] event=$event $details".trimEnd()
        return publish(line)
    }

    private fun publish(line: String): String {
        val sanitized = LogSanitizer.sanitize(line)
        val structured = Regex("^(?:\\S+\\s+)?\\[(?:DEBUG|INFO|WARN|ERROR)\\]\\s+\\[").containsMatchIn(sanitized)
        val safe = if (structured) {
            if (sanitized.startsWith("[")) "${Instant.now()} $sanitized" else sanitized
        } else "${Instant.now()} [pppd] $sanitized"
        onLine(safe)
        sink?.success(safe)
        return safe
    }

    suspend fun beginCapture() {
        readMutex.withLock {
            val state = snapshot()
            val endsWithNewline = state.size == 0L || withContext(Dispatchers.IO) {
                read("tail -c 1 $path | base64").trim() == "Cg=="
            }
            cursor.seekToEnd(state.identity, state.size, endsWithNewline)
            capturing = true
        }
        ensurePolling()
    }

    fun endCapture() {
        capturing = false
        if (sink == null) closePolling()
    }

    suspend fun drain() = readMutex.withLock {
        val state = snapshot()
        val window = cursor.window(state.identity, state.size)
        if (window.reset) event("INFO", "log_reset", "reason=rotation_or_restart")
        if (window.skipped > 0) event("WARN", "logs_truncated", "skipped_bytes=${window.skipped}")
        if (window.count > 0) {
            val encoded = withContext(Dispatchers.IO) {
                read("tail -c +${window.start + 1} $path | head -c ${window.count} | base64")
            }
            currentCoroutineContext().ensureActive()
            val bytes = Base64.getMimeDecoder().decode(encoded)
            cursor.consume(bytes).filter { it.isNotBlank() }.forEach { publish(it) }
        }
    }

    private fun ensurePolling() {
        if (job?.isActive == true) return
        job = scope.launch {
            while (isActive) {
                try {
                    drain()
                    if (lastError != null) event("INFO", "capture_recovered")
                    lastError = null
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    val message = e.message ?: "Root log read failed"
                    if (message != lastError) event("WARN", "capture_error", message)
                    lastError = message
                }
                delay(if (lastError == null) 1000 else 5000)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        ensurePolling()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        if (!capturing) closePolling()
    }

    private fun closePolling() {
        job?.cancel()
        job = null
    }

    fun close() {
        sink = null
        capturing = false
        closePolling()
    }
}
