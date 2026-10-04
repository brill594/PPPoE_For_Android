package com.brill.pppoe_controller.vpn

import android.app.*
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.ResultReceiver
import android.util.Patterns
import com.brill.pppoe_controller.bridge.PppoeBridge
import kotlinx.coroutines.*

class PppoeVpnService : VpnService() {
    companion object {
        @Volatile
        var isActive: Boolean = false
            private set
        const val ACT_START = "START_VPN"
        const val ACT_STOP = "STOP_VPN"
        const val EXTRA_RESULT = "result"
        private const val NOTI_CH = "pppoe_vpn"
        private const val NOTI_ID = 101
    }

    private var tun: ParcelFileDescriptor? = null
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var startJob: Job? = null
    private var pendingResult: ResultReceiver? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        @Suppress("DEPRECATION")
        val receiver = intent?.getParcelableExtra<ResultReceiver>(EXTRA_RESULT)
        if (intent?.action != ACT_START) {
            try {
                releaseVpn()
                stopSelf()
                receiver?.send(1, null)
            } catch (e: Exception) {
                receiver?.send(0, Bundle().apply { putString("error", e.message ?: "VPN close failed") })
            }
            return START_NOT_STICKY
        }
        if (startJob?.isActive == true) {
            receiver?.send(0, Bundle().apply { putString("error", "VPN start already pending") })
            return START_NOT_STICKY
        }
        pendingResult = receiver
        try {
            val mgr = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(NotificationChannel(NOTI_CH, "PPPoE VPN", NotificationManager.IMPORTANCE_LOW))
            startForeground(NOTI_ID, notification("Starting PPPoE DNS container"))
            startJob = scope.launch {
                try {
                    val details = establishVpn()
                    pendingResult?.send(1, Bundle().apply { putString("details", details) })
                    pendingResult = null
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failStart(e)
                }
            }
        } catch (e: Exception) {
            failStart(e)
        }
        return START_NOT_STICKY
    }

    private fun failStart(e: Exception) {
        pendingResult?.send(0, Bundle().apply { putString("error", e.message ?: "VPN establishment failed") })
        pendingResult = null
        runCatching { releaseVpn() }.onFailure {
            android.util.Log.e("PppoeVpnService", "Unable to release failed VPN", it)
        }
        stopSelf()
    }

    private suspend fun establishVpn(): String {
        val prefs = getSharedPreferences("pppoe_settings", MODE_PRIVATE)
        val custom = if (prefs.getBoolean("use_custom_dns", false)) {
            listOfNotNull(prefs.getString("custom_dns1", null), prefs.getString("custom_dns2", null))
                .map { it.trim() }.filter { Patterns.IP_ADDRESS.matcher(it).matches() }
        } else emptyList()
        val dns = if (custom.isNotEmpty()) custom else {
            val peer = withContext(Dispatchers.IO) { PppoeBridge.readPeerEnv() }
            listOfNotNull(peer["DNS1"], peer["DNS2"])
                .filter { Patterns.IP_ADDRESS.matcher(it).matches() }
        }
        val servers = dns.distinct().ifEmpty { listOf("8.8.8.8") }
        // Routing to PPP is owned by the module; this TUN is only a DNS container.
        val builder = Builder()
            .setSession("PPPoE-DNS-Container")
            .addAddress("10.0.0.1", 32)
            .addRoute("203.0.113.0", 24)
            .setBlocking(false)
            .setMetered(false)
            .allowBypass()
        servers.forEach { builder.addDnsServer(it) }
        val established = checkNotNull(builder.establish()) { "VPN permission was revoked" }
        val previous = tun
        tun = established
        isActive = true
        runCatching { previous?.close() }
        startForeground(NOTI_ID, notification("DNS: ${servers.joinToString(", ")}"))
        val source = if (custom.isNotEmpty()) "custom" else if (dns.isNotEmpty()) "peer" else "fallback"
        return "dns_source=$source dns=${servers.joinToString(",")}"
    }

    private fun notification(text: String): Notification {
        val pi = PendingIntent.getActivity(this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, NOTI_CH)
            .setContentTitle("PPPoE DNS Container")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(pi)
            .build()
    }

    private fun releaseVpn() {
        startJob?.cancel()
        startJob = null
        pendingResult?.send(0, Bundle().apply { putString("error", "VPN service stopped") })
        pendingResult = null
        // Android can keep a stopped VpnService bound. Close the TUN before
        // stopSelf instead of relying on a later onDestroy callback.
        tun?.close()
        tun = null
        isActive = false
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onRevoke() {
        scope.launch {
            runCatching { releaseVpn() }.onFailure {
                android.util.Log.e("PppoeVpnService", "Unable to release revoked VPN", it)
            }
            stopSelf()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        runCatching { releaseVpn() }.onFailure {
            android.util.Log.e("PppoeVpnService", "Unable to release destroyed VPN", it)
        }
        isActive = false
        super.onDestroy()
    }
}
