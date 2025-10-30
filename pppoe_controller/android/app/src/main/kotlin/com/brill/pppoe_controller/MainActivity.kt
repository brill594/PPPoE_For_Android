package com.brill.pppoe_controller
import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.vpn.PppoeVpnService
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences // <-- MODIFIED: 1. 添加了 SharedPreferences 导入
import android.net.VpnService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.ActivityResult
import java.io.BufferedReader
import java.io.File
import com.brill.pppoe_controller.db.AppDatabase
import com.brill.pppoe_controller.db.LogEntry
import kotlinx.coroutines.* import java.util.concurrent.CopyOnWriteArrayList
import android.util.Log
import com.topjohnwu.superuser.Shell

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "pppoe/bridge"
    private val LOG_CHANNEL = "pppoe/log_stream"
    private val db by lazy { AppDatabase.getDatabase(this) }
    private val logBuffer = CopyOnWriteArrayList<String>()
    private var isCapturingLog = false
    private val coroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var monitoringJob: Job? = null
    private val mainScope = CoroutineScope(Dispatchers.Main)
    private var flutterResult: MethodChannel.Result? = null
    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result: ActivityResult ->
        if (result.resultCode == RESULT_OK) {
            this.flutterResult?.success(true)
        } else {
            this.flutterResult?.success(false)
        }
        this.flutterResult = null
    }

    private var logStreamProcess: Process? = null
    private var logStreamReader: BufferedReader? = null

    // --- Prefs Constants ---
    private val PREFS_NAME = "pppoe_settings"
    private val KEY_CUSTOM_DNS_ENABLED = "use_custom_dns"
    private val KEY_CUSTOM_DNS1 = "custom_dns1"
    private val KEY_CUSTOM_DNS2 = "custom_dns2"
    // --- MODIFIED: 2. 添加了新的 Key ---
    private val KEY_SPEED_TEST_URL = "speedTestUrl"
    // ---

    private val logStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            if (events == null) return

            Thread {
                try {
                    val logFile = File("/data/local/tmp/pppoe.log")
                    if (!logFile.exists()) {
                        logFile.createNewFile()
                    }

                    logStreamProcess = ProcessBuilder("tail", "-F", logFile.absolutePath)
                        .redirectErrorStream(true)
                        .start()

                    logStreamReader = logStreamProcess?.inputStream?.bufferedReader()

                    logStreamReader?.forEachLine { line ->
                        if (line.isNotBlank()) {
                            this@MainActivity.runOnUiThread {
                                events.success(line)
                                if (isCapturingLog) {
                                    logBuffer.add(line)
                                    if (logBuffer.size > 1000) {
                                        logBuffer.removeFirstOrNull()
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    this@MainActivity.runOnUiThread {
                        events.error("LOG_STREAM_ERROR", e.message, null)
                    }
                } finally {
                    onCancel(null)
                }
            }.start()
        }

        override fun onCancel(arguments: Any?) {
            try {
                logStreamReader?.close()
                logStreamProcess?.destroy()
            } catch (e: Exception) {
                // 忽略
            }
            logStreamReader = null
            logStreamProcess = null
        }
    }

    private fun startDialingAndCaptureLog(flutterResult: MethodChannel.Result) {
        monitoringJob?.cancel()
        logBuffer.clear()
        isCapturingLog = true
        val startTime = System.currentTimeMillis()
        var finalStatus = "Unknown"
        var savedLogId: Long? = null
        Log.d("MainActivity", "Starting dialing attempt and log capture.")

        Thread {
            val startSuccess = PppoeBridge.control("start")
            if (!startSuccess) {
                Log.e("MainActivity", "PppoeBridge.control('start') failed immediately.")
                isCapturingLog = false
                finalStatus = "Failure (Control)"
                coroutineScope.launch {
                    saveLogAttempt(startTime, finalStatus)
                }
                this@MainActivity.runOnUiThread {
                    flutterResult.error("START_FAILED", "Failed to send start command", null)
                }
                return@Thread
            }

            monitoringJob = coroutineScope.launch {
                var connectionUp = false
                for (i in 0 until 10) {
                    try {
                        val pingSuccess = PppoeBridge.checkConnectivity()

                        if (pingSuccess) {
                            Log.d("MainActivity", "Ping check successful.")
                            connectionUp = true
                            finalStatus = "Success (Ping)"
                            break
                        } else {
                            Log.d("MainActivity", "Ping check failed, attempt ${i + 1}/10.")
                        }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Error during connectivity check", e)
                    }
                    delay(500)
                }

                if (!connectionUp && isActive) {
                    Log.w("MainActivity", "Connectivity check timed out after ~15 seconds.")
                    finalStatus = "Timeout (Ping)"
                }

                isCapturingLog = false
                savedLogId = saveLogAttempt(startTime, finalStatus)

                withContext(Dispatchers.Main) {
                    val resultMap = mapOf(
                        "status" to finalStatus,
                        "logId" to savedLogId
                    )
                    if (finalStatus.startsWith("Success")) {
                        flutterResult.success(resultMap)
                    } else {
                        flutterResult.success(resultMap)
                    }
                }
            }

            runBlocking { monitoringJob?.join() }

        }.start()
    }

    private suspend fun saveLogAttempt(startTime: Long, status: String): Long? {
        val capturedLog = logBuffer.joinToString("\n")
        logBuffer.clear()
        val entry = LogEntry(
            timestamp = startTime,
            logContent = capturedLog,
            status = status
        )
        return try {
            val insertedId = db.logEntryDao().insert(entry)
            Log.d("MainActivity", "Saved log attempt with ID: $insertedId, Status: $status")
            insertedId
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to save log entry to database", e)
            null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        monitoringJob?.cancel()
        coroutineScope.cancel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL)
            .setStreamHandler(logStreamHandler)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                Log.d("MainActivity", "MethodChannel received call: ${call.method}")
                when (call.method) {
                    "writeCreds" -> {
                        val user = call.argument<String>("user")
                        val pass = call.argument<String>("pass")
                        if (user == null || pass == null) {
                            result.error("INVALID_ARGS", "User or pass cannot be null", null)
                        } else {
                            Thread {
                                val success = PppoeBridge.writeCreds(user, pass)
                                this@MainActivity.runOnUiThread { result.success(success) }
                            }.start()
                        }
                    }
                    "writeIface" -> {
                        val iface = call.argument<String>("iface")
                        Thread {
                            val success = PppoeBridge.writeIface(iface)
                            this@MainActivity.runOnUiThread { result.success(success) }
                        }.start()
                    }
                    "writeMtuMru" -> {
                        val mtu = call.argument<Int>("mtu")
                        val mru = call.argument<Int>("mru")
                        if (mtu == null || mru == null) {
                            result.error("INVALID_ARGS", "MTU or MRU cannot be null", null)
                        } else {
                            Thread {
                                val success = PppoeBridge.writeMtuMru(mtu, mru)
                                this@MainActivity.runOnUiThread { result.success(success) }
                            }.start()
                        }
                    }
                    "control" -> {
                        val cmd = call.argument<String>("cmd")
                        if (cmd == null) {
                            result.error("INVALID_ARGS", "Command cannot be null", null)
                        } else {
                            Thread {
                                val success = PppoeBridge.control(cmd)
                                this@MainActivity.runOnUiThread { result.success(success) }
                            }.start()
                        }
                    }


                    "readPeerEnv" -> {
                        Thread {
                            val env = PppoeBridge.readPeerEnv()
                            this@MainActivity.runOnUiThread { result.success(env) }
                        }.start()
                    }
                    "prepareVpn" -> {
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            this.flutterResult = result
                            vpnPermissionLauncher.launch(intent)
                        } else {
                            result.success(true)
                        }
                    }
                    "updateLogStatus" -> {
                        val id = call.argument<Long>("id")
                        val status = call.argument<String>("status")
                        if (id == null || status == null) {
                            result.error("INVALID_ARGS", "ID and Status cannot be null", null)
                        } else {
                            coroutineScope.launch {
                                val entry = db.logEntryDao().getById(id)
                                if (entry != null) {
                                    entry.status = status
                                    db.logEntryDao().update(entry)
                                    Log.d("MainActivity", "Updated log entry $id status to: $status")
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
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_STOP)
                        startService(i)
                        result.success(true)
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
                        coroutineScope.launch {
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
                        Log.d("MainActivity", "[DEBUG] Received 'startVpn' call from Flutter.")
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_START)
                        startForegroundService(i)
                        Log.d("MainActivity", "[DEBUG] Called startForegroundService for PppoeVpnService.")
                        result.success(true)
                    }
                    "getLogDetails" -> {
                        val idAsNumber = call.argument<Number>("id")
                        val id = idAsNumber?.toLong()

                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            mainScope.launch {
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
                            mainScope.launch {
                                val success = withContext(Dispatchers.IO) {
                                    val entry = db.logEntryDao().getById(id)
                                    if (entry != null) {
                                        entry.note = note
                                        db.logEntryDao().update(entry)
                                        true
                                    } else {
                                        false
                                    }
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
                        mainScope.launch {
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
                        Log.d("MainActivity", "Handling 'getNetworkInterfaces' call.")
                        Thread {
                            var interfaces: List<String> = emptyList()
                            try {
                                val command = "ls /sys/class/net"
                                Log.d("MainActivity", "Executing root command: $command")

                                val result = Shell.cmd(command).exec()

                                if (result.isSuccess) {
                                    interfaces = result.out
                                        .filterNotNull()
                                        .filter { it.isNotBlank() }
                                        .map { it.trim() }
                                        .sorted()
                                    Log.d("MainActivity", "Root command success. Interfaces found: $interfaces")
                                } else {
                                    Log.e("MainActivity", "Root command '$command' failed. Code: ${result.code}, Error: ${result.err.joinToString("\n")}")
                                    interfaces = emptyList()
                                }

                            } catch (e: Exception) {
                                Log.e("MainActivity", "Error executing root command for interfaces", e)
                                interfaces = emptyList()
                            } finally {
                                this@MainActivity.runOnUiThread {
                                    Log.d("MainActivity", "Returning interface list: $interfaces")
                                    result.success(interfaces)
                                }
                            }
                        }.start()
                    }

                    // --- MODIFIED: 3. 添加了两个新的分支 ---
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
                    // --- 结束 MODIFIED ---

                    else -> result.notImplemented()
                }
            }
    }

}