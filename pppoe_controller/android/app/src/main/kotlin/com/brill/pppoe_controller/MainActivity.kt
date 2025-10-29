package com.brill.pppoe_controller
import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.vpn.PppoeVpnService
import com.brill.pppoe_controller.su.RootShell
import android.content.Context // 添加 Context import
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterFragmentActivity // 注意：基类改为了 FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel // 1. 导入 EventChannel
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.ActivityResult
import android.app.Activity.RESULT_OK
import java.io.BufferedReader // 2. 导入 BufferedReader
import java.io.File
import com.brill.pppoe_controller.db.AppDatabase // Add DB import
import com.brill.pppoe_controller.db.LogEntry    // Add LogEntry import
import com.brill.pppoe_controller.db.LogSummary  // Add LogSummary import
import kotlinx.coroutines.* // Add Coroutine imports
import java.util.concurrent.CopyOnWriteArrayList
import android.util.Log
import com.topjohnwu.superuser.Shell

class MainActivity : FlutterFragmentActivity() { // 注意：基类改为了 FragmentActivity
    private val CHANNEL = "pppoe/bridge"
    private val LOG_CHANNEL = "pppoe/log_stream" // 3. 新的日志流通道
    private val db by lazy { AppDatabase.getDatabase(this) } // Lazy init DB
    private val logBuffer = CopyOnWriteArrayList<String>() // Thread-safe buffer for current attempt
    private var isCapturingLog = false
    private val coroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()) // Scope for DB operations
    private var monitoringJob: Job? = null // Job for monitoring dial attempt
    // --- VPN 权限 ---
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

    // --- 日志流 ---
    private var logStreamProcess: Process? = null
    private var logStreamReader: BufferedReader? = null
    private val PREFS_NAME = "pppoe_settings"
    private val KEY_CUSTOM_DNS_ENABLED = "use_custom_dns"
    private val KEY_CUSTOM_DNS1 = "custom_dns1"
    private val KEY_CUSTOM_DNS2 = "custom_dns2"
    // 4. 定义 EventChannel StreamHandler
    private val logStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            if (events == null) return

            // 切换到后台线程来运行 'tail -F'
            Thread {
                try {
                    val logFile = File("/data/local/tmp/pppoe.log")
                    if (!logFile.exists()) {
                        logFile.createNewFile() // 确保文件存在
                    }

                    // 运行 'tail -F' 命令。我们不需要 root，因为 /data/local/tmp 是可读的
                    logStreamProcess = ProcessBuilder("tail", "-F", logFile.absolutePath)
                        .redirectErrorStream(true) // 合并 stdout/stderr
                        .start()

                    logStreamReader = logStreamProcess?.inputStream?.bufferedReader()

                    // 逐行读取并发送
                    logStreamReader?.forEachLine { line ->
                        if (line.isNotBlank()) {
                            this@MainActivity.runOnUiThread {
                                // Always send to live stream
                                events.success(line)
                                // If capturing, also add to buffer
                                if (isCapturingLog) {
                                    logBuffer.add(line)
                                    // Optional: Limit buffer size to prevent memory issues
                                    if (logBuffer.size > 1000) { // Keep last 1000 lines
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
                    // 确保在流结束时清理
                    onCancel(null)
                }
            }.start()
        }

        override fun onCancel(arguments: Any?) {
            // 当 Flutter 停止监听时，关闭进程
            try {
                logStreamReader?.close()
                logStreamProcess?.destroy()
            } catch (e: Exception) {
                // 忽略清理错误
            }
            logStreamReader = null
            logStreamProcess = null
        }
    }

    private fun startDialingAndCaptureLog(flutterResult: MethodChannel.Result) {
        monitoringJob?.cancel() // Cancel previous monitoring if any
        logBuffer.clear()
        isCapturingLog = true
        val startTime = System.currentTimeMillis()
        var finalStatus = "Unknown" // Default status
        var savedLogId: Long? = null // 用于保存日志 ID
        Log.d("MainActivity", "Starting dialing attempt and log capture.")

        // Initiate the 'start' command in background
        Thread {
            val startSuccess = PppoeBridge.control("start")
            if (!startSuccess) {
                Log.e("MainActivity", "PppoeBridge.control('start') failed immediately.")
                isCapturingLog = false // Stop capturing early
                finalStatus = "Failure (Control)"
                // Save attempt immediately
                coroutineScope.launch {
                    saveLogAttempt(startTime, finalStatus) // Call suspend fun from coroutine
                }
                this@MainActivity.runOnUiThread {
                    flutterResult.error("START_FAILED", "Failed to send start command", null)
                }
                return@Thread // Exit this thread
            }

            // Start monitoring in a coroutine
            monitoringJob = coroutineScope.launch {
                var dnsFound = false
                // Monitor for max 15 seconds (adjust timeout as needed)
                for (i in 0 until 30) { // 30 * 500ms = 15 seconds
                    try {
                        val peer = PppoeBridge.readPeerEnv() // This runs in the coroutine's IO context
                        if (!peer["DNS1"].isNullOrBlank() || !peer["DNS2"].isNullOrBlank()) {
                            Log.d("MainActivity", "DNS found in peer env.")
                            dnsFound = true
                            finalStatus = "Success"
                            break // Exit loop on success
                        }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Error reading peer env during monitoring", e)
                        // Continue loop, maybe it's a temporary read error
                    }
                    delay(500) // Wait 500ms
                }

                if (!dnsFound && isActive) { // Check isActive to ensure job wasn't cancelled
                    Log.w("MainActivity", "Dialing attempt timed out after 15 seconds.")
                    finalStatus = "Timeout"
                }else if (isActive) { // 确保 job 未被取消
                    // 只有在明确找到 DNS 时才设置 Success
                    finalStatus = "Success (DNS)" // 更明确的状态
                }

                // Regardless of outcome, stop capturing and save
                isCapturingLog = false
                saveLogAttempt(startTime, finalStatus)

                // Report final status back to Flutter on main thread
                withContext(Dispatchers.Main) {
                    val resultMap = mapOf(
                        "status" to finalStatus,
                        "logId" to savedLogId // 将 ID 也返回
                    )
                    if (finalStatus.startsWith("Success")) {
                        flutterResult.success(resultMap) // 成功时返回 Map
                    } else {
                        // 失败或超时也用 success 返回 Map，让 Dart 处理错误逻辑
                        flutterResult.success(resultMap)
                        // 或者你可以选择用 error 返回，但这会进入 Dart 的 catch 块
                        // flutterResult.error("DIAL_FAILED", "Dialing failed or timed out. Status: $finalStatus", resultMap)
                    }
                }
            }

            // Wait for the monitoring job to complete (or be cancelled)
            // This keeps the Thread alive until monitoring finishes
            runBlocking { monitoringJob?.join() } // Use runBlocking carefully

        }.start() // Start the thread that runs control("start") and manages monitoring
    }

    // 返回插入的 ID (Long)，如果失败则返回 null
    private suspend fun saveLogAttempt(startTime: Long, status: String): Long? { // 修改返回类型
        val capturedLog = logBuffer.joinToString("\n")
        logBuffer.clear()
        val entry = LogEntry(
            timestamp = startTime,
            logContent = capturedLog,
            status = status
        )
        return try {
            val insertedId = db.logEntryDao().insert(entry) // insert 返回 Long
            Log.d("MainActivity", "Saved log attempt with ID: $insertedId, Status: $status")
            insertedId // 返回 ID
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to save log entry to database", e)
            null // 保存失败返回 null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        monitoringJob?.cancel() // Cancel monitoring if activity is destroyed
        coroutineScope.cancel() // Cancel the coroutine scope
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 5. 注册新的 EventChannel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL)
            .setStreamHandler(logStreamHandler)

        // 6. 注册你的 MethodChannel (已全部使用后台线程)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                Log.d("MainActivity", "MethodChannel received call: ${call.method}") // <-- 日志 A
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
                                    entry.status = status // 更新状态
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
                        startDialingAndCaptureLog(result) // Call new function
                    }
                    "stopVpn" -> {
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_STOP)
                        startService(i)
                        result.success(true)
                    }
                    // --- History Methods ---
                    "getLogHistory" -> {
                        coroutineScope.launch {
                            val history = db.logEntryDao().getAllSummaries()
                            // Convert to Map for Flutter compatibility
                            val historyMapList = history.map {
                                mapOf("id" to it.id, "timestamp" to it.timestamp, "note" to it.note, "status" to it.status)
                            }
                            withContext(Dispatchers.Main) {
                                result.success(historyMapList)
                            }
                        }
                    }
                    "startVpn" -> {
                        Log.d("MainActivity", "[DEBUG] Received 'startVpn' call from Flutter.") // <-- Add Log
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_START)
                        startForegroundService(i)
                        Log.d("MainActivity", "[DEBUG] Called startForegroundService for PppoeVpnService.") // <-- Add Log
                        result.success(true)
                    }
                    "getLogDetails" -> {
                        val id = call.argument<Long>("id")
                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            coroutineScope.launch {
                                val entry = db.logEntryDao().getById(id)
                                withContext(Dispatchers.Main) {
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
                    }
                    "updateLogNote" -> {
                        val id = call.argument<Long>("id")
                        val note = call.argument<String?>("note") // Allow null note
                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            coroutineScope.launch {
                                val entry = db.logEntryDao().getById(id)
                                if (entry != null) {
                                    entry.note = note // Update the note
                                    db.logEntryDao().update(entry)
                                    withContext(Dispatchers.Main) { result.success(true) }
                                } else {
                                    withContext(Dispatchers.Main) { result.error("NOT_FOUND", "Log entry not found", null) }
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
                        prefs.putString(KEY_CUSTOM_DNS1, dns1?.trim()) // 保存 trim 后的值
                        prefs.putString(KEY_CUSTOM_DNS2, dns2?.trim())
                        prefs.apply() // 异步保存
                        result.success(true)
                    }
                    // --- 新增: 读取 DNS 设置 ---
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
                        val id = call.argument<Long>("id")
                        if (id == null) {
                            result.error("INVALID_ARGS", "ID cannot be null", null)
                        } else {
                            coroutineScope.launch {
                                db.logEntryDao().deleteById(id)
                                withContext(Dispatchers.Main) { result.success(true) }
                            }
                        }
                    }

                    "getNetworkInterfaces" -> {
                        Log.d("MainActivity", "Handling 'getNetworkInterfaces' call.") // Log B
                        // Switch to a background thread
                        Thread {
                            var interfaces: List<String> = emptyList()
                            try {
                                // Use RootShell to execute 'ls /sys/class/net'
                                val command = "ls /sys/class/net"
                                Log.d("MainActivity", "Executing root command: $command") // Log 1

                                // We need the output, not just success/fail, so use Shell.cmd(...).toResult()
                                val result = Shell.cmd(command).exec() // Execute and get result object

                                if (result.isSuccess) {
                                    // result.out contains the list of interface names, one per line
                                    interfaces = result.out
                                        .filterNotNull()      // Filter out potential null lines
                                        .filter { it.isNotBlank() } // Filter out empty lines
                                        .map { it.trim() }     // Trim whitespace
                                        .sorted()             // Sort alphabetically
                                    Log.d("MainActivity", "Root command success. Interfaces found: $interfaces") // Log 2
                                } else {
                                    // Log failure if the root command failed
                                    Log.e("MainActivity", "Root command '$command' failed. Code: ${result.code}, Error: ${result.err.joinToString("\n")}") // Log 3
                                    interfaces = emptyList()
                                }

                            } catch (e: Exception) {
                                // Log any exceptions during the process
                                Log.e("MainActivity", "Error executing root command for interfaces", e) // Log 4
                                interfaces = emptyList()
                            } finally {
                                // Always return the result (even if empty) to the main thread
                                this@MainActivity.runOnUiThread {
                                    Log.d("MainActivity", "Returning interface list: $interfaces") // Log 5
                                    result.success(interfaces)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

}