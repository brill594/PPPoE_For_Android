package com.brill.pppoe_controller
import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.vpn.PppoeVpnService
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.ActivityResult

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "pppoe/bridge"

    // 1. 保存 Flutter 的 result 回调
    private var flutterResult: MethodChannel.Result? = null

    // 2. 注册新的 Activity Result 启动器
    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result:ActivityResult ->
        // 3. 这是用户点击 "OK" 或 "Cancel" 后的回调
        if (result.resultCode == RESULT_OK) {
            // 用户授予了权限
            this.flutterResult?.success(true)
        } else {
            // 用户拒绝了权限
            this.flutterResult?.success(false)
        }
        // 清理回调，防止内存泄漏
        this.flutterResult = null
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "writeCreds" -> {
                        val user = call.argument<String>("user")
                        val pass = call.argument<String>("pass")

                        if (user == null || pass == null) {
                            result.error("INVALID_ARGS", "User or pass cannot be null", null)
                        } else {
                            // 切换到后台线程
                            Thread {
                                val success = PppoeBridge.writeCreds(user, pass)
                                // 回到主线程发送结果
                                this@MainActivity.runOnUiThread {
                                    result.success(success)
                                }
                            }.start()
                        }
                    }
                    "writeIface" -> {
                        val iface = call.argument<String>("iface")

                        // 切换到后台线程
                        Thread {
                            val success = PppoeBridge.writeIface(iface)
                            // 回到主线程发送结果
                            this@MainActivity.runOnUiThread {
                                result.success(success)
                            }
                        }.start()
                    }
                    "writeMtuMru" -> {
                        val mtu = call.argument<Int>("mtu")
                        val mru = call.argument<Int>("mru")

                        if (mtu == null || mru == null) {
                            result.error("INVALID_ARGS", "MTU or MRU cannot be null", null)
                        } else {
                            // 切换到后台线程
                            Thread {
                                val success = PppoeBridge.writeMtuMru(mtu, mru)
                                // 回到主线程发送结果
                                this@MainActivity.runOnUiThread {
                                    result.success(success)
                                }
                            }.start()
                        }
                    }
                    "control" -> {
                        val cmd = call.argument<String>("cmd")
                        if (cmd == null) {
                            result.error("INVALID_ARGS", "Command cannot be null", null)
                        } else {
                            // 1. 切换到后台线程
                            Thread {
                                val success = PppoeBridge.control(cmd)
                                // 2. 回到主线程来发送结果
                                this@MainActivity.runOnUiThread {
                                    result.success(success)
                                }
                            }.start()
                        }
                    }
                    "readLog" -> {
                        // 1. 切换到后台线程
                        Thread {
                            val log = PppoeBridge.readLog()
                            // 2. 回到主线程来发送结果
                            this@MainActivity.runOnUiThread {
                                result.success(log)
                            }
                        }.start()
                    }
                    "readPeerEnv" -> {
                        Thread {
                            val env = PppoeBridge.readPeerEnv()
                            this@MainActivity.runOnUiThread {
                                result.success(env)
                            }
                        }.start()
                    }
                    "prepareVpn" -> {
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            // 1. 保存 Flutter 的 result，以便在回调中使用
                            this.flutterResult = result
                            // 2. 启动权限请求
                            vpnPermissionLauncher.launch(intent)
                            // 注意：这里不再调用 result.success(false)
                            // 结果将在上面的回调中异步发送
                        } else {
                            // 权限已经有了
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
                    else -> result.notImplemented()
                }
            }
    }
}
