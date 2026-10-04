package com.brill.pppoe_controller
import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.vpn.PppoeVpnService
import android.content.Context
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.ActivityResult
import com.brill.pppoe_controller.db.AppDatabase
import com.brill.pppoe_controller.db.LogEntry
import kotlinx.coroutines.*
import com.brill.pppoe_controller.su.RootShell
import com.brill.pppoe_controller.logging.RootLogStream
import com.brill.pppoe_controller.logging.AttemptLog
import com.brill.pppoe_controller.logging.LogSanitizer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "pppoe/bridge"
    private val LOG_CHANNEL = "pppoe/log_stream"
    private val db by lazy { AppDatabase.getDatabase(this) }
    private var currentAttempt: AttemptLog? = null
    private var captureReady = false
    private var lastLogId: Long? = null
    private val mainScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var monitoringJob: Job? = null
    private var dialResult: MethodChannel.Result? = null
    private var flutterResult: MethodChannel.Result? = null
    private var vpnStartResult: MethodChannel.Result? = null
    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result: ActivityResult ->
        recordEvent(if (result.resultCode == RESULT_OK) "INFO" else "WARN",
            if (result.resultCode == RESULT_OK) "vpn_permission_granted" else "vpn_permission_denied")
        flutterResult?.success(result.resultCode == RESULT_OK)
        flutterResult = null
    }

    private fun launchResult(result: MethodChannel.Result, block: suspend () -> Unit): Job =
        mainScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                result.error("OPERATION_FAILED", e.message, null)
            }
        }

    private fun ioResult(result: MethodChannel.Result, block: () -> Any?) {
        launchResult(result) { result.success(withContext(Dispatchers.IO) { block() }) }
    }

    private val PREFS_NAME = "pppoe_settings"
    private val KEY_CUSTOM_DNS_ENABLED = "use_custom_dns"
    private val KEY_CUSTOM_DNS1 = "custom_dns1"
    private val KEY_CUSTOM_DNS2 = "custom_dns2"
    private val KEY_SPEED_TEST_URL = "speedTestUrl"

    private val logStreamHandler = RootLogStream(mainScope, onLine = { line ->
        if (captureReady) currentAttempt?.add(line)
    })

    private fun recordEvent(level: String, event: String, details: String = "") {
        val attempt = currentAttempt
        val line = logStreamHandler.event(level, event,
            listOfNotNull(attempt?.let { "attempt=${it.id}" }, details.takeIf { it.isNotEmpty() }).joinToString(" "))
        if (!captureReady) attempt?.add(line)
        // VPN authorization/establishment occurs after the dialing record is inserted.
        val id = lastLogId
        if (attempt == null && id != null) {
            mainScope.launch {
                try {
                    withContext(Dispatchers.IO) { db.logEntryDao().appendLog(id, "\n$line") }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    logStreamHandler.event("WARN", "history_write_failed", "Unable to append lifecycle event")
                }
            }
        }
    }

    private fun cancelDialing() {
        val attempt = currentAttempt
        if (attempt != null) recordEvent("INFO", "attempt_cancelled", "reason=user_or_activity_stop")
        currentAttempt = null
        captureReady = false
        logStreamHandler.endCapture()
        monitoringJob?.cancel()
        monitoringJob = null
        dialResult?.error("CANCELLED", "Dialing cancelled", null)
        dialResult = null
        if (attempt != null) {
            val entry = LogEntry(timestamp = attempt.startedAt, logContent = attempt.content(), status = "Cancelled")
            mainScope.launch(start = CoroutineStart.UNDISPATCHED) {
                withContext(NonCancellable + Dispatchers.IO) {
                    try {
                        db.logEntryDao().insert(entry)
                    } catch (e: Exception) {
                        android.util.Log.e("PPPoE", "Unable to persist cancelled attempt", e)
                    }
                }
            }
        }
    }

    private fun startDialingAndCaptureLog(result: MethodChannel.Result) {
        if (monitoringJob?.isActive == true) {
            result.error("BUSY", "A dialing attempt is already running", null)
            return
        }
        val attempt = AttemptLog()
        currentAttempt = attempt
        captureReady = false
        lastLogId = null
        dialResult = result
        monitoringJob = mainScope.launch {
            try {
                val status = try {
                    logStreamHandler.beginCapture()
                    captureReady = true
                    recordEvent("INFO", "attempt_start")
                    check(withContext(Dispatchers.IO) { PppoeBridge.control("start") }) {
                        "Failed to send start command"
                    }
                    recordEvent("INFO", "command_sent", "action=start")
                    delay(1500)
                    var connected = false
                    for (probe in 1..30) {
                        if (withContext(Dispatchers.IO) { PppoeBridge.checkConnectivity() }) {
                            connected = true
                            break
                        }
                        // Each probe is detailed evidence, hidden by the default log view.
                        recordEvent("DEBUG", "link_probe", "interface=ppp0 probe=$probe result=not_ready")
                        delay(1000)
                    }
                    if (connected) "Success (PPPoE Link)" else "Timeout (PPPoE Link)"
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (!captureReady) recordEvent("INFO", "attempt_start")
                    "Failure (${e.message ?: "Root operation failed"})"
                }
                if (captureReady) {
                    try {
                        logStreamHandler.drain()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        recordEvent("WARN", "capture_error", e.message ?: "Final log read failed")
                    }
                }
                val elapsed = System.currentTimeMillis() - attempt.startedAt
                when {
                    status.startsWith("Success") -> recordEvent("INFO", "attempt_success", "elapsed_ms=$elapsed interface=ppp0")
                    status.startsWith("Timeout") -> recordEvent("WARN", "attempt_timeout", "elapsed_ms=$elapsed reason=ppp0_link_not_ready")
                    else -> recordEvent("ERROR", "attempt_failed", status)
                }
                val entry = LogEntry(timestamp = attempt.startedAt, logContent = attempt.content(), status = LogSanitizer.sanitize(status))
                // Freeze the completed attempt before the database suspension; a stop
                // during insertion must not create a second cancelled copy.
                currentAttempt = null
                captureReady = false
                logStreamHandler.endCapture()
                val logId = withContext(Dispatchers.IO) { db.logEntryDao().insert(entry) }
                lastLogId = logId
                result.success(mapOf("status" to status, "logId" to logId))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                recordEvent("ERROR", "history_write_failed", "Unable to save dialing record")
                result.error("START_FAILED", e.message, null)
            } finally {
                if (dialResult === result) {
                    currentAttempt = null
                    captureReady = false
                    logStreamHandler.endCapture()
                    dialResult = null
                }
            }
        }
    }

    override fun onDestroy() {
        cancelDialing()
        logStreamHandler.close()
        flutterResult?.error("CANCELLED", "Activity destroyed", null)
        flutterResult = null
        vpnStartResult?.error("CANCELLED", "Activity destroyed", null)
        vpnStartResult = null
        mainScope.cancel()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL)
            .setStreamHandler(logStreamHandler)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                when (call.method) {
                    "writeCreds" -> {
                        val user = call.argument<String>("user")
                        val pass = call.argument<String>("pass")
                        if (user == null || pass == null) {
                            result.error("INVALID_ARGS", "User or pass cannot be null", null)
                        } else {
                            ioResult(result) { PppoeBridge.writeCreds(user, pass) }
                        }
                    }
                    "writeIface" -> {
                        val iface = call.argument<String>("iface")
                        ioResult(result) { PppoeBridge.writeIface(iface) }
                    }
                    "writeMtuMru" -> {
                        val mtu = call.argument<Int>("mtu")
                        val mru = call.argument<Int>("mru")
                        if (mtu == null || mru == null) {
                            result.error("INVALID_ARGS", "MTU or MRU cannot be null", null)
                        } else {
                            ioResult(result) { PppoeBridge.writeMtuMru(mtu, mru) }
                        }
                    }
                    "control" -> {
                        val cmd = call.argument<String>("cmd")
                        if (cmd == null) {
                            result.error("INVALID_ARGS", "Command cannot be null", null)
                        } else {
                            if (cmd == "stop" || cmd == "cycle") cancelDialing()
                            ioResult(result) { PppoeBridge.control(cmd) }
                        }
                    }


                    "readPeerEnv" -> {
                        ioResult(result) { PppoeBridge.readPeerEnv() }
                    }
                    "getConnectionState" -> {
                        ioResult(result) {
                            val state = PppoeBridge.getConnectionState()
                            mapOf("peer" to state.peer, "connected" to state.connected,
                                "running" to state.running, "pendingCommand" to state.pendingCommand,
                                "vpnActive" to PppoeVpnService.isActive)
                        }
                    }
                    "prepareVpn" -> {
                        if (flutterResult != null) {
                            result.error("BUSY", "VPN permission request already pending", null)
                            return@setMethodCallHandler
                        }
                        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        val intent = VpnService.prepare(this)
                        if (call.argument<Boolean>("firstLaunchOnly") == true &&
                            prefs.getBoolean("vpn_prompted", false)) {
                            result.success(intent == null)
                            return@setMethodCallHandler
                        }
                        prefs.edit().putBoolean("vpn_prompted", true).apply()
                        recordEvent("INFO", "vpn_prepare_requested")
                        if (intent != null) {
                            this.flutterResult = result
                            try {
                                vpnPermissionLauncher.launch(intent)
                            } catch (e: Exception) {
                                flutterResult = null
                                throw e
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "updateLogStatus" -> {
                        val id = call.argument<Number>("id")?.toLong()
                        val status = call.argument<String>("status")
                        if (id == null || status == null) {
                            result.error("INVALID_ARGS", "ID and Status cannot be null", null)
                        } else {
                            launchResult(result) {
                                val updated = withContext(Dispatchers.IO) { db.logEntryDao().updateStatus(id, LogSanitizer.sanitize(status)) }
                                if (updated > 0) {
                                    withContext(Dispatchers.Main) { result.success(true) }
                                } else {
                                    withContext(Dispatchers.Main) { result.error("NOT_FOUND", "Log entry not found for status update", null) }
                                }
                            }
                        }
                    }
                    "startDialingAttempt" -> {
                        startDialingAndCaptureLog(result)
                    }
                    "stopVpn" -> {
                        vpnStartResult?.error("CANCELLED", "VPN start cancelled", null)
                        vpnStartResult = null
                        recordEvent("INFO", "vpn_stop_requested")
                        launchResult(result) {
                            val stopped = withTimeoutOrNull(4000) {
                                suspendCancellableCoroutine<Boolean> { continuation ->
                                    val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                                        override fun onReceiveResult(code: Int, data: Bundle?) {
                                            if (!continuation.isActive) return
                                            if (code == 1) continuation.resume(true)
                                            else continuation.resumeWithException(IllegalStateException(
                                                data?.getString("error") ?: "VPN close failed"))
                                        }
                                    }
                                    startService(Intent(this@MainActivity, PppoeVpnService::class.java)
                                        .setAction(PppoeVpnService.ACT_STOP)
                                        .putExtra(PppoeVpnService.EXTRA_RESULT, receiver))
                                }
                            }
                            check(stopped == true) { "VPN stop acknowledgement timed out" }
                            recordEvent("INFO", "vpn_stopped")
                            result.success(true)
                        }
                    }
                    "shareLogAsText" -> {
                        try {
                            val text = call.argument<String>("text")
                            val subject = call.argument<String>("subject")

                            if (text == null || subject == null) {
                                result.error("INVALID_ARGS", "Text or Subject cannot be null", null)
                                return@setMethodCallHandler
                            }

                            val sendIntent = Intent().apply {
                                action = Intent.ACTION_SEND
                                putExtra(Intent.EXTRA_TEXT, text)
                                putExtra(Intent.EXTRA_SUBJECT, subject)
                                type = "text/plain"
                            }
                            val shareIntent = Intent.createChooser(sendIntent, "Share Log via...")
                            startActivity(shareIntent)

                            result.success(true)

                        } catch (e: Exception) {
                            result.error("SHARE_ERROR", e.message, e.stackTraceToString())
                        }
                    }
                    "getLogHistory" -> {
                        launchResult(result) {
                            val history = db.logEntryDao().getAllSummaries()
                            val historyMapList = history.map {
                                mapOf("id" to it.id, "timestamp" to it.timestamp, "note" to it.note, "status" to it.status)
                            }
                            withContext(Dispatchers.Main) {
                                result.success(historyMapList)
                            }
                        }
                    }
                    "startVpn" -> {
                        if (vpnStartResult != null) {
                            result.error("BUSY", "VPN start already pending", null)
                            return@setMethodCallHandler
                        }
                        vpnStartResult = result
                        val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                            override fun onReceiveResult(code: Int, data: Bundle?) {
                                if (vpnStartResult !== result) return
                                vpnStartResult = null
                                if (code == 1) {
                                    recordEvent("INFO", "vpn_started", data?.getString("details") ?: "")
                                    result.success(true)
                                } else {
                                    recordEvent("ERROR", "vpn_failed", data?.getString("error") ?: "VPN could not start")
                                    result.error("VPN_FAILED", data?.getString("error") ?: "VPN could not start", null)
                                }
                            }
                        }
                        try {
                            startForegroundService(Intent(this, PppoeVpnService::class.java)
                                .setAction(PppoeVpnService.ACT_START)
                                .putExtra(PppoeVpnService.EXTRA_RESULT, receiver))
                        } catch (e: Exception) {
                            vpnStartResult = null
                            recordEvent("ERROR", "vpn_failed", e.message ?: "VPN service launch failed")
                            result.error("VPN_FAILED", e.message, null)
                        }
                    }
                    "getLogDetails" -> {
                        val idAsNumber = call.argument<Number>("id")
                        val id = idAsNumber?.toLong()

                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            launchResult(result) {
                                val entry = withContext(Dispatchers.IO) {
                                    db.logEntryDao().getById(id)
                                }

                                if (entry != null) {
                                    result.success(mapOf(
                                        "id" to entry.id,
                                        "timestamp" to entry.timestamp,
                                        "note" to entry.note,
                                        "logContent" to entry.logContent,
                                        "status" to entry.status
                                    ))
                                } else {
                                    result.error("NOT_FOUND", "Log entry not found", null)
                                }
                            }
                        }
                    }

                    "updateLogNote" -> {
                        val idAsNumber = call.argument<Number>("id")
                        val id = idAsNumber?.toLong()
                        val note = call.argument<String?>("note")

                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            launchResult(result) {
                                val success = withContext(Dispatchers.IO) {
                                    db.logEntryDao().updateNote(id, note) > 0
                                }

                                if (success) {
                                    result.success(true)
                                } else {
                                    result.error("NOT_FOUND", "Log entry not found", null)
                                }
                            }
                        }
                    }
                    "saveDnsSettings" -> {
                        val useCustom = call.argument<Boolean>("useCustom")
                        val dns1 = call.argument<String>("dns1")
                        val dns2 = call.argument<String>("dns2")
                        if (useCustom == null) {
                            result.error("INVALID_ARGS", "useCustom is required", null)
                            return@setMethodCallHandler
                        }
                        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                        prefs.putBoolean(KEY_CUSTOM_DNS_ENABLED, useCustom)
                        prefs.putString(KEY_CUSTOM_DNS1, dns1?.trim())
                        prefs.putString(KEY_CUSTOM_DNS2, dns2?.trim())
                        prefs.apply()
                        result.success(true)
                    }
                    "loadDnsSettings" -> {
                        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        val settings = mapOf(
                            "useCustom" to prefs.getBoolean(KEY_CUSTOM_DNS_ENABLED, false),
                            "dns1" to prefs.getString(KEY_CUSTOM_DNS1, ""),
                            "dns2" to prefs.getString(KEY_CUSTOM_DNS2, "")
                        )
                        result.success(settings)
                    }
                    "deleteLogEntry" -> {
                        val idAsNumber = call.argument<Number>("id")
                        val id = idAsNumber?.toLong()
                        if (id == null) {
                            result.error("INVALID_ARG", "ID is null or not a number", null)
                            return@setMethodCallHandler
                        }
                        launchResult(result) {
                            try {
                                val rowsDeleted = withContext(Dispatchers.IO) {
                                    db.logEntryDao().deleteById(id)
                                }
                                result.success(rowsDeleted > 0)
                            } catch (e: Exception) {
                                result.error(
                                    "DB_ERROR",
                                    "Error during database operation: ${e.message}",
                                    e.stackTraceToString()
                                )
                            }
                        }
                    }
                    "getNetworkInterfaces" -> {
                        ioResult(result) {
                            RootShell.read("ls /sys/class/net").lineSequence()
                                .map { it.trim() }.filter { it.isNotBlank() }.sorted().toList()
                        }
                    }

                    "saveSpeedTestUrl" -> {
                        try {
                            val url = call.argument<String>("url")
                            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                            prefs.putString(KEY_SPEED_TEST_URL, url).apply() // 使用常量
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SAVE_ERROR", e.message, e.stackTraceToString())
                        }
                    }

                    "loadSpeedTestUrl" -> {
                        try {
                            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                            // 提供默认值
                            val url = prefs.getString(KEY_SPEED_TEST_URL, "https://speed.cloudflare.com/__down?bytes=10000000")
                            result.success(url)
                        } catch (e: Exception) {
                            result.error("LOAD_ERROR", e.message, e.stackTraceToString())
                        }
                    }

                    else -> result.notImplemented()
                }
                } catch (e: Exception) {
                    result.error("OPERATION_FAILED", e.message, null)
                }
            }
    }

}