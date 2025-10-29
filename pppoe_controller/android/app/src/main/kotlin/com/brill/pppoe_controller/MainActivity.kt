package com.brill.pppoe_controller
import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.vpn.PppoeVpnService
import com.brill.pppoe_controller.su.RootShell
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
import java.io.InputStreamReader
import java.net.NetworkInterface
import android.util.Log
import com.topjohnwu.superuser.Shell

class MainActivity : FlutterFragmentActivity() { // 注意：基类改为了 FragmentActivity
    private val CHANNEL = "pppoe/bridge"
    private val LOG_CHANNEL = "pppoe/log_stream" // 3. 新的日志流通道

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
                            // 必须在主线程上发送
                            this@MainActivity.runOnUiThread {
                                events.success(line)
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

                    // *** 删除了 "readLog" ***
                    // 它现在被上面的 EventChannel 处理了

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
                    "startVpn" -> {
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_START)
                        startForegroundService(i)
                        result.success(true)
                    }
                    "stopVpn" -> {
                        val i = Intent(this, PppoeVpnService::class.java)
                            .setAction(PppoeVpnService.ACT_STOP)
                        startService(i)
                        result.success(true)
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