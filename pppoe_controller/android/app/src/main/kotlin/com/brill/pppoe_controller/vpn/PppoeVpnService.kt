package com.brill.pppoe_controller.vpn
import android.app.*
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.brill.pppoe_controller.bridge.PppoeBridge
import android.util.Log
import android.content.Context
import android.util.Patterns

class PppoeVpnService : VpnService() {
    companion object {
        const val ACT_START = "START_VPN"
        const val ACT_STOP  = "STOP_VPN"
        private const val NOTI_CH = "pppoe_vpn"
        private const val NOTI_ID = 101
    }

    private var tun: ParcelFileDescriptor? = null
    private val PREFS_NAME = "pppoe_settings"
    private val KEY_CUSTOM_DNS_ENABLED = "use_custom_dns"
    private val KEY_CUSTOM_DNS1 = "custom_dns1"
    private val KEY_CUSTOM_DNS2 = "custom_dns2"

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d("PppoeVpnService", "[DEBUG] onStartCommand received action: ${intent?.action}")
        when (intent?.action) {
            ACT_START -> startVpn()
            ACT_STOP  -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        Log.d("PppoeVpnService", "[DEBUG] startVpn() called.")
        createNotification()
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val useCustomDns = prefs.getBoolean(KEY_CUSTOM_DNS_ENABLED, false)
        val customDns1 = prefs.getString(KEY_CUSTOM_DNS1, null)?.takeIf { Patterns.IP_ADDRESS.matcher(it).matches() } // 读取并验证 IP
        val customDns2 = prefs.getString(KEY_CUSTOM_DNS2, null)?.takeIf { Patterns.IP_ADDRESS.matcher(it).matches() } // 读取并验证 IP

        val builder = Builder()
            .setSession("PPPoE-DNS-Container")
            .addAddress("10.0.0.1", 32)
            .addRoute("203.0.113.0", 24)
            .setBlocking(false)
            .setMetered(false)
            .allowBypass()

        if (!customDns1.isNullOrBlank()) builder.addDnsServer(customDns1)
        if (!customDns2.isNullOrBlank()) builder.addDnsServer(customDns2)


        var dnsApplied = false
        var dnsStatusText = "DNS: Default (PPPoE)"

        if (useCustomDns && customDns1 != null) {
            Log.d("PppoeVpnService", "Applying custom DNS: $customDns1, $customDns2")
            builder.addDnsServer(customDns1)
            if (customDns2 != null) {
                builder.addDnsServer(customDns2)
            }
            dnsApplied = true
            dnsStatusText = "DNS: Custom ($customDns1${if (customDns2 != null) ", $customDns2" else ""})"
        }

        if (!dnsApplied) {
            val peer = PppoeBridge.readPeerEnv()
            val peerDns1 = peer["DNS1"]?.takeIf { Patterns.IP_ADDRESS.matcher(it).matches() }
            val peerDns2 = peer["DNS2"]?.takeIf { Patterns.IP_ADDRESS.matcher(it).matches() }

            Log.d("PppoeVpnService", "Applying PPPoE DNS: $peerDns1, $peerDns2")
            if (peerDns1 != null) {
                builder.addDnsServer(peerDns1)
                dnsApplied = true
            }
            if (peerDns2 != null) {
                builder.addDnsServer(peerDns2)
                dnsApplied = true
            }
            dnsStatusText = "DNS: PPPoE (${peerDns1 ?: "-"}, ${peerDns2 ?: "-"})"
        }

        if (!dnsApplied) {
            Log.w("PppoeVpnService", "No valid DNS found from custom or PPPoE, adding fallback DNS 8.8.8.8")
            builder.addDnsServer("8.8.8.8") // 例如 Google DNS
            dnsStatusText = "DNS: Fallback (8.8.8.8)"
        }
        tun = builder.establish()
        if (tun == null) {
            Log.e("PppoeVpnService", "Failed to establish VPN tunnel, likely permission issue.")
            startForeground(NOTI_ID, notification("VPN Permission Required or Failed"))
            stopVpn()
            return
        }
        startForeground(NOTI_ID, notification(dnsStatusText))
    }

    private fun stopVpn() {
        tun?.close()
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createNotification() {
        val mgr = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            mgr.createNotificationChannel(NotificationChannel(NOTI_CH, "PPPoE VPN", NotificationManager.IMPORTANCE_LOW))
        }
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

    override fun onRevoke() { stopVpn() }
}
